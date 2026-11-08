'use strict';

// De brug tussen een app-pagina (/app-ui/…) en de Stulp-app.
//
// De pagina staat zelf, top-level, in een WKWebView van de native app. Elke
// aanroep gaat als één bericht naar de message handler `stulp` (een
// WKScriptMessageHandlerWithReply), dus postMessage geeft een promise terug:
//
//   window.webkit.messageHandlers.stulp.postMessage({
//     action:  'get' | 'set' | 'unset' | 'api' | 'emit' | 'showView' |
//              'nextView' | 'prevView' | 'close' | 'title' | 'openURL' |
//              'alert' | 'confirm' | 'ready' | 'navigationClose',
//     args:    per action hieronder,
//     context: window.__STULP_CONTEXT__   // {appId, sessionId, …} van de server
//   })  →  Promise<antwoord>, of een afwijzing met de foutmelding als tekst
//
//   get        {name}                       → de waarde, of null als hij er niet is
//   set        {name, value}                → true
//   unset      {name}                       → true
//   api        {method, path, body}         → het antwoord van /api/stulp/apps/<appId>/api/<path>
//   emit       {event, data}                → het antwoord van de pair-handler <event>
//   showView   {view}                       → true
//   nextView   {}  prevView {}  close {}    → true
//   title      {title}                      → true
//   openURL    {url}                        → true (de app opent hem buiten de pagina)
//   alert      {message, type}              → true
//   confirm    {message, type}              → true of false
//   ready      {}  navigationClose {}       → true
//
// De andere kant op roept de app `window.__stulpEvent(name, data)` aan via
// evaluateJavaScript; dat gaat naar de luisteraars van Stulp.on(name, …).
(function stulpBridge() {
  const context = window.__STULP_CONTEXT__ || {};
  const strings = window.__STULP_LOCALE__ || {};
  const listeners = new Map();

  function request(action, args) {
    const host = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.stulp;
    if (!host) return Promise.reject(new Error('Deze pagina hoort in de Stulp-app.'));
    return Promise.resolve(host.postMessage({ action, args, context })).then(
      value => (value === undefined ? null : value),
      error => { throw error instanceof Error ? error : new Error(String(error)); });
  }

  function callback(promise, done) {
    if (typeof done === 'function') promise.then(value => done(null, value), error => done(error));
    return promise;
  }

  function translate(key, tags = {}) {
    let value = key.split('.').reduce((node, part) => node && node[part], strings);
    if (typeof value !== 'string') value = key;
    for (const [name, replacement] of Object.entries(tags || {})) {
      value = value.replaceAll(`:${name}`, String(replacement)).replaceAll(`{${name}}`, String(replacement));
    }
    return value;
  }

  window.__stulpEvent = (event, data) => {
    for (const listener of listeners.get(event) || []) listener(data);
  };

  // element bouwt één stukje pagina. Zes plugins schreven hier hun eigen
  // variant van, en de een noemde het node en de ander bouwde het met de hand.
  function element(tag, className, text) {
    const made = document.createElement(tag);
    if (className) made.className = className;
    if (text !== undefined && text !== null) made.textContent = text;
    return made;
  }

  const Stulp = {
    __: translate,

    // De paginahulp. Alles hieronder is er omdat het anders in elke plugin
    // opnieuw geschreven wordt: get, set, api en emit geven zelf al een promise
    // terug, dus er hoort ook nergens een new Promise omheen.
    $(id) { return document.getElementById(id); },
    node: element,

    // row is één gevonden ding: naam links, bijzonderheden rechts.
    row(name, detail, className) {
      const made = element('div', className ? 'row ' + className : 'row');
      made.append(element('span', '', name));
      if (detail !== undefined && detail !== null && detail !== '') {
        made.append(element('small', '', detail));
      }
      return made;
    },

    // say zet de melding op de vaste plek van de pagina. kind is 'ok', 'bad' of
    // 'busy' -- zie app-frame.css.
    say(message, kind) {
      const status = document.getElementById('status');
      if (!status) return;
      status.textContent = message || '';
      status.className = 'hint' + (kind ? ' ' + kind : '');
    },

    get(name, done) { return callback(request('get', { name }), done); },
    set(name, value, done) { return callback(request('set', { name, value }), done); },
    unset(name, done) { return callback(request('unset', { name }), done); },
    api(method, path, body, done) { return callback(request('api', { method, path, body }), done); },
    emit(event, data, done) { return callback(request('emit', { event, data }), done); },
    on(event, listener) {
      const current = listeners.get(event) || [];
      current.push(listener);
      listeners.set(event, current);
      return Stulp;
    },
    ready() { request('ready', {}).catch(() => {}); },
    // openURL laat de app een adres buiten de pagina openen (OAuth, een
    // handleiding). In de webview zelf navigeren zou de pagina vervangen.
    openURL(url, done) { return callback(request('openURL', { url: String(url) }), done); },
    alert(message, type, done) { return callback(request('alert', { message: String(message), type }), done); },
    confirm(message, type, done) { return callback(request('confirm', { message: String(message), type }), done); },
    setTitle(title) { request('title', { title: String(title) }).catch(() => {}); },
    showView(view) { return request('showView', { view }); },
    nextView() { return request('nextView', {}); },
    prevView() { return request('prevView', {}); },
    close() { return request('close', {}); },
    showLoadingOverlay() { document.documentElement.classList.add('stulp-loading'); },
    hideLoadingOverlay() { document.documentElement.classList.remove('stulp-loading'); },
    setNavigationClose() { request('navigationClose', {}).catch(() => {}); },
  };

  window.Stulp = Stulp;
  window.__ = translate;
  window.addEventListener('DOMContentLoaded', () => {
    document.querySelectorAll('[data-i18n]').forEach(node => {
      const value = translate(node.getAttribute('data-i18n'));
      if (node instanceof HTMLInputElement && node.placeholder) node.placeholder = value;
      else node.textContent = value;
    });
  });
  window.addEventListener('load', () => {
    if (typeof window.onStulpReady === 'function') window.onStulpReady(Stulp);
  });
})();
