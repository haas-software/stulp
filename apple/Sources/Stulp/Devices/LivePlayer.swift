import StulpKit
import SwiftUI
import WebKit

/// A camera's live stream. Stulp passes the camera's fragmented MP4 through as it comes, without an
/// end; AVPlayer only plays files and HLS, so the stream is fed to WebKit's Media Source Extensions
/// (ManagedMediaSource on iPhone and iPad) in a page of our own. The page runs on Stulp's origin,
/// so its `fetch` carries the key as a Bearer header and the stream URL never needs it.
struct LivePlayer {
    let client: StulpClient
    let path: String

    @MainActor
    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        #endif
        configuration.preferences.isElementFullscreenEnabled = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isInspectable = true
        #if os(iOS)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        #else
        view.setValue(false, forKey: "drawsBackground")
        #endif
        view.loadHTMLString(Self.page(path: path, authorization: client.connection.authorization), baseURL: client.connection.baseURL)
        return view
    }

    /// Navigating away (closing the view) cancels the fetch, which closes the stream at Stulp.
    @MainActor
    static func stop(_ view: WKWebView) {
        view.evaluateJavaScript("window.stulpStop && window.stulpStop()")
        view.loadHTMLString("", baseURL: nil)
    }

    static func page(path: String, authorization: String) -> String {
        let config = (try? String(data: JSONEncoder().encode(["url": path, "authorization": authorization]), encoding: .utf8)) ?? "{}"
        return #"""
        <!doctype html>
        <html lang="nl"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>
          html,body{margin:0;height:100%;background:#000;color:#fff;font:15px -apple-system,system-ui,sans-serif;overflow:hidden}
          #frame{position:fixed;inset:0;display:flex;align-items:center;justify-content:center;background:#000}
          video{width:100%;height:100%;object-fit:contain;background:#000}
          #status{position:fixed;left:16px;right:16px;bottom:max(24px,env(safe-area-inset-bottom));text-align:center;color:rgba(255,255,255,.85);text-shadow:0 1px 3px #000}
          #status:empty{display:none}
        </style></head>
        <body><div id="frame"><video id="video" playsinline muted autoplay disableremoteplayback></video><div id="status">Verbinden…</div></div>
        <script>
        const config = \#(config);
        const video = document.getElementById('video');
        const statusLine = document.getElementById('status');
        const say = text => { statusLine.textContent = text; };
        let stopAll = () => {};
        window.stulpStop = () => stopAll();

        // Double-click (Mac) toggles full screen of the frame, so the status line stays on top.
        document.getElementById('frame').addEventListener('dblclick', () => {
          if (document.fullscreenElement) document.exitFullscreen?.();
          else document.getElementById('frame').requestFullscreen?.().catch(() => {});
        });

        async function play() {
          const controller = new AbortController();
          let stopped = false;
          stopAll = () => { stopped = true; controller.abort(); video.removeAttribute('src'); video.srcObject = null; video.load(); };
          const response = await fetch(config.url, { headers: { Authorization: config.authorization }, signal: controller.signal });
          if (!response.ok || !response.body) {
            throw new Error(response.status === 404 ? 'De app levert deze stream niet.' : `De stream gaf ${response.status}.`);
          }
          // The full media type, codecs included, comes from the plugin; without it the player
          // cannot say whether it can play this.
          const type = response.headers.get('content-type') || 'video/mp4';
          const Source = window.ManagedMediaSource || window.MediaSource;
          if (!Source || !Source.isTypeSupported(type)) {
            response.body.cancel();
            throw new Error(`Dit toestel kan ${type} niet als livestream afspelen.`);
          }

          const source = new Source();
          const reader = response.body.getReader();
          // What came in and what the player took. Only with both can a still picture be explained:
          // no bytes is a camera that sends nothing, bytes without fragments is a codec refused.
          let received = 0, appended = 0, failure = '', gapListener = null;
          const stall = setTimeout(() => {
            if (stopped || !video.paused) return;
            if (received === 0) fail('Er komt geen beeld binnen van deze camera.');
            else if (appended === 0) fail(`De speler nam ${type} niet aan.`);
            else fail('Er komt beeld binnen, maar de speler start niet.');
          }, 15000);
          const settled = () => clearTimeout(stall);
          // The first error stays: once the player stumbles, every later append fails with a
          // message about that earlier error, which tells nothing.
          const fail = message => { if (failure) return; failure = message; settled(); say(message); };
          const previousStop = stopAll;
          stopAll = () => { settled(); if (gapListener) video.removeEventListener('waiting', gapListener); reader.cancel().catch(() => {}); previousStop(); };

          video.disableRemotePlayback = true;
          if ('srcObject' in video && window.ManagedMediaSource && source instanceof window.ManagedMediaSource) {
            video.srcObject = source;
          } else {
            video.src = URL.createObjectURL(source);
          }
          video.addEventListener('playing', () => { settled(); say(''); }, { once: true });
          video.addEventListener('error', () => {
            fail(video.error?.message ? `De speler stopte: ${video.error.message}` : `Dit toestel speelt ${type} niet af.`);
          }, { once: true });

          source.addEventListener('sourceopen', async () => {
            if (stopped) return;
            let buffer;
            try { buffer = source.addSourceBuffer(type); }
            catch (error) { fail(`Dit toestel kan ${type} niet inlezen: ${error.message}`); return; }
            // A slow viewer resumes after a missed fragment on the next keyframe, which leaves two
            // buffered ranges; jump to the next one when the playhead has no picture.
            const jump = () => {
              const ranges = buffer.buffered;
              if (!ranges.length) return false;
              const now = video.currentTime;
              for (let i = 0; i < ranges.length; i++) {
                const start = ranges.start(i), end = ranges.end(i);
                if (now < start) { video.currentTime = start; return true; }
                if (now <= end) {
                  if (i + 1 < ranges.length && end - now < 0.05) { video.currentTime = ranges.start(i + 1); return true; }
                  return false;
                }
              }
              return false;
            };
            gapListener = jump;
            video.addEventListener('waiting', gapListener);
            // Live: what is past need not be kept, or the buffer grows until the player drops it.
            buffer.mode = 'segments';
            const queue = [];
            const pump = () => {
              if (stopped || failure || buffer.updating || !queue.length) return;
              try {
                buffer.appendBuffer(queue[0]);
                queue.shift();
                appended++;
              } catch (error) {
                if (error.name === 'QuotaExceededError') {
                  const buffered = buffer.buffered;
                  if (buffered.length && video.currentTime - buffered.start(0) > 4) {
                    try { buffer.remove(buffered.start(0), video.currentTime - 2); } catch {}
                    return;
                  }
                }
                fail(`De speler nam dit beeld niet aan: ${video.error?.message || error.message}`);
              }
            };
            buffer.addEventListener('error', () => {
              fail(video.error?.message ? `De speler kon dit beeld niet lezen: ${video.error.message}` : 'De speler kon dit beeld niet lezen.');
            });
            buffer.addEventListener('updateend', () => {
              const buffered = buffer.buffered;
              if (!buffered.length) return pump();
              // The picture may start anywhere on the timeline (raw RTP timestamps); a player waits
              // at zero forever without an error, so go to where the picture is.
              const jumped = jump();
              if (!jumped && video.currentTime - buffered.start(0) > 30 && !buffer.updating) {
                try { buffer.remove(buffered.start(0), video.currentTime - 10); } catch {}
              }
              pump();
            });
            try {
              for (;;) {
                const { done, value } = await reader.read();
                if (done || stopped) break;
                received += value.byteLength;
                queue.push(value);
                pump();
                if (video.paused) video.play().catch(() => {});
              }
            } catch {}
            settled();
            if (!stopped && source.readyState === 'open') {
              try { source.endOfStream(); } catch {}
              if (!failure) say('De camera stopte met sturen.');
            }
          }, { once: true });
        }

        play().catch(error => { if (error.name !== 'AbortError') say(error.message || String(error)); });
        </script></body></html>
        """#
    }
}

#if os(iOS)
extension LivePlayer: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView() }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: ()) { stop(view) }
}
#else
extension LivePlayer: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView() }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: ()) { stop(view) }
}
#endif
