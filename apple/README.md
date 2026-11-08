# Stulp voor iPhone, iPad en Mac

De native app van **Stulp**: je huis bedienen, apparaten toevoegen, scènes en Flows maken, en
Stulp beheren. De app praat met de HTTP-API van je eigen Stulp, met de toegangssleutel
(`STULP_TOKEN`) als Bearer-token. Stulp heeft zelf geen webinterface meer; de enige HTML is
wat een app zelf meebrengt (zijn instellingenpagina en koppelschermen), en die toont deze app in
een webview. De API staat in [`../docs/web-api.md`](../docs/web-api.md).

Eén SwiftUI-app voor iPhone (ook de opvouwbare iPhone Duo), iPad en Mac (`platform: auto`,
`supportedDestinations: [iOS, macOS]`; de destination kiest het platform). De indeling volgt
Apple's Woning-app.

- **iPhone:** onderin *Thuis* en de locaties op het eerste niveau (Beneden, Eerste etage, Tuin),
  elk met het icoon uit de ruimte-editor. *Thuis* toont bovenaan de categorieën (Klimaat,
  Verlichting, Beveiliging, …) met wat er speelt, daaronder de scènes, de camera's en per ruimte de
  tegels. Elke titel is een klein glazen kapsel dat meescrolt en bovenin blijft staan tot het
  volgende hem wegduwt, zoals de maand in Haas Foto's. Een locatie (en een ruimte waarop je tikt)
  is dezelfde pagina voor alleen dat deel van het huis: zijn categorieën, scènes, camera's (ook in
  een subruimte) en ruimtes. Tik op het symbool van een tegel om hem te
  schakelen, op de rest voor de bediening; lang drukken geeft verplaatsen en verwijderen. Het menu
  (…) bovenin leidt naar *Automatisering*, *Meldingen* en *Instellingen*; de plus voegt een
  apparaat (ook een fabrieksnieuw Matter-apparaat via Apple's eigen scherm) of een ruimte toe.
- **Automatisering:** een Flow op een canvas, zoals Stulp hem altijd tekende: kaarten (Als blauw,
  En oranje, Dan groen) waar je ze neerzet, lijnen van een uitgang naar de volgende kaart. Slepen
  verplaatst, vanaf de uitgang slepen verbindt (of tik de uitgang en dan de kaart), het bolletje
  midden op een lijn haalt hem weg, knijpen zoomt, dubbeltikken zet een kaart neer
  (`Flows/FlowCanvas.swift`).
- **iPad en een opengevouwen Duo:** dezelfde tabbladen als zijbalk, met ook de categorieën,
  *Automatisering* en *Instellingen* erin, zoals Woning op de iPad.
- **Mac:** een venster met zijbalk (*Thuis*, de categorieën, de ruimtes, *Automatisering*,
  *Meldingen*, *Apps*) en de instellingen in ⌘,. ⌘N voegt een apparaat toe, ⌘R vernieuwt. Geen
  Matter-koppeling, meldingen of thuis/weg: dat is werk van de telefoon.
- **Wat deze iPhone voor Stulp doet** (Instellingen): de telefoon is een apparaat van de
  Meldingen-app (`com.stulp.notify`). Stulp stuurt er meldingen naartoe via APNs, ook met
  camerabeeld (`StulpNotification` haalt het beeld op); tikken op zo'n melding opent die camera.
  De telefoon meldt thuis en weg met een geofence (`PresenceMonitor`: binnen 300 m thuis, buiten
  150 m weg, ook als de app dicht is) en aan de lader via een Opdrachten-actie
  (`StulpIntents`).

Live: de app houdt één event-stream (`/api/stulp/events`) open zolang hij actief is. Bij het
openen neemt hij een momentopname; een `device.update` draagt het hele apparaat en wordt direct
toegepast, de rest herlaadt wat hij raakt. Bedienen toont de nieuwe waarde meteen en zet hem
terug als Stulp weigert.

Swift 6 met strikte concurrency, `@Observable`-modellen, geen externe afhankelijkheden.

## Opbouw

```
apple/
├── project.yml                 XcodeGen; het .xcodeproj wordt gegenereerd
├── Sources/
│   ├── StulpKit/               framework zonder UI, ook voor de Matter-extensie
│   │   ├── StulpClient.swift       de API met Bearer-token
│   │   ├── EventStream.swift       de live-stream (server-sent events)
│   │   ├── Models.swift, Flows.swift   apparaten, ruimtes, scènes, apps, drivers, Flows, kaarten
│   │   ├── Presentation.swift      wat een tegel zegt: waarde, woorden, symbool, categorie
│   │   ├── MatterCommissioning.swift  de iPhone-helft van een Matter-koppeling
│   │   └── StulpConfiguration.swift   verbinding in de sleutelhanger, app-groep, thuis/weg
│   ├── Stulp/                  de app
│   │   ├── Models/HomeModel.swift  het huis: live apparaten, ruimtes, op verzoek de rest
│   │   ├── RootView.swift          tabbladen (iOS) of zijbalkvenster (Mac)
│   │   ├── Home/                   Thuis, categorieën, ruimtes, tegels, camera's
│   │   ├── Devices/                bediening en instellingen van één apparaat
│   │   ├── Flows/                  Automatisering: de Flow op een canvas, de kaartkiezer, de velden
│   │   ├── Scenes/                 scènes maken en bewerken
│   │   ├── Pairing/                apparaat toevoegen, apps
│   │   ├── Web/                    de webview voor de pagina's van een app (stulp.js-brug)
│   │   ├── Settings/               verbinden, instellingen, ruimtes, meldingen, backup
│   │   └── iOS/                    push, thuis/weg, Opdrachten
│   ├── StulpMatterSetup/       Matter Setup Extension (alleen iOS)
│   └── StulpNotification/      Notification Service Extension: camerabeeld bij een melding
├── Tests/StulpKitTests/        Swift Testing: verbinding, client, stream, modellen, weergave, kaartzinnen
└── tools/                      testflight.sh, build-ipa.sh, set-apns-key.sh
```

## Bouwen

Xcode 27 en [XcodeGen](https://github.com/yonaskolb/XcodeGen). Het project wordt uit
`project.yml` gegenereerd:

```sh
cd apple
xcodegen generate
xcodebuild -project Stulp.xcodeproj -scheme Stulp -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project Stulp.xcodeproj -scheme Stulp -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Stulp.xcodeproj -scheme Stulp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

De tests draaien het snelst op macOS. Ze dekken het lezen van adres en sleutel, de Bearer-header
op elk verzoek, foutmeldingen, de Matter-koppeling van start tot sluiten (ook bij een fout), de
event-stream, het decoderen van echte apparaten en wat een tegel toont. QR, BLE, wifi/Thread en
echte commissioning zijn grenzen van Apple's frameworks en hardware; die moeten op een fysieke
iPhone met echte Matter-apparaten worden gevalideerd.

## Lokaal proberen

Met een verse Stulp en virtuele apparaten (vanuit `stulp/`, na `./build.sh`). Een app vindt zijn
programma als `<map>/<app-id>` naast zijn `app.json`; kopieer de plugin dus eerst:

```sh
mkdir -p /tmp/stulp-dev/virtualdevices
cp -R plugins/virtualdevices/. /tmp/stulp-dev/virtualdevices/
cp target/release/stulp-virtualdevices /tmp/stulp-dev/virtualdevices/com.stulp.virtualdevices
target/release/stulp-host --document /tmp/stulp-dev/stulp.json install /tmp/stulp-dev/virtualdevices
STULP_TOKEN=dev target/release/stulp-host --document /tmp/stulp-dev/stulp.json serve --listen 127.0.0.1:8080
```

Debug-builds kennen deze startargumenten (in het schema staan ze klaar, uitgevinkt):

| | |
|---|---|
| `-stulpAddress http://127.0.0.1:8080 -stulpKey dev` | verbinden zonder onboarding |
| `-stulpDemo YES` | een gevuld demohuis zonder server, voor previews en schermafbeeldingen |
| `-stulpTab automations\|settings\|apps\|notifications` | met dat tabblad openen |
| `-stulpOpen <device-id>` | meteen de bediening van dat apparaat openen |
| `-stulpSettings rooms\|notifications` | met `-stulpTab settings`: meteen die pagina van Instellingen openen |

Bijvoorbeeld in de simulator:

```sh
xcrun simctl launch booted software.haas.stulp -stulpAddress http://127.0.0.1:8080 -stulpKey dev
```

## Op een echt toestel

Signing staat op automatisch met team `QVY3KR44QS`; de Matter-extensie heeft de entitlement
*Matter Allow Setup Payload* omdat zij de onboardingcode rechtstreeks ontvangt. Met het
Apple-account van dat team in Xcode, de iPhone met een kabel aangesloten, de Mac vertrouwd en
Ontwikkelaarsmodus aan (Instellingen, Privacy en beveiliging):

```sh
tools/build-ipa.sh install
```

Dat genereert het project, bouwt eenmaal tegen de iPhone zodat Xcode hem in het profiel
registreert, archiveert met development-signing, exporteert `build/Stulp.ipa` en installeert met
`devicectl`. Een development-build blijft zeven dagen geldig op een gratis account en een jaar op
een betaald account.

De app gebruikt dezelfde bundle-id (`software.haas.stulp`), app-groep en sleutelhangergroep als de
eerdere WebView-app; een bestaande installatie houdt dus zijn adres en sleutel, zijn gekozen
toestel en zijn thuislocatie. Alleen de oude Manage-link werkt niet meer als link: plak hem bij
het verbinden in het adresveld, dan haalt de app de sleutel eruit.

Meldingen via APNs vragen Apple's sleutel in de Meldingen-app van Stulp:

```sh
apple/tools/set-apns-key.sh ~/Downloads/AuthKey_XXXXXXXXXX.p8 [https://demo.gethop.org]
```

## TestFlight

```sh
tools/testflight.sh export          # ondertekenen voor App Store Connect, zonder te uploaden
tools/testflight.sh                 # iOS archiveren en uploaden
tools/testflight.sh upload ios macos   # ook de Mac, zodra het app-record macOS heeft
```

Zoals bij Haas Drive: automatische signing (met de App Store Connect-sleutel uit
`~/Git/haas.software/AUTH/appstoreconnect.env` als die er is, anders het Xcode-account), en het
buildnummer is de tijd (`YYYYMMDD.HHMM`) voor app en extensies tegelijk. Het app-record met
bundle-id `software.haas.stulp` moet in App Store Connect bestaan.

## Matter

Een fabrieksnieuw Matter-apparaat gaat via **+ → Apparaat toevoegen → Matter-apparaat** naar
Apple's eigen QR- en setupscherm. iOS doet de tijdelijke BLE- en netwerkbootstrap; de Matter
Setup Extension geeft de onboardingcode aan de gewone koppel-API van Stulp. Stulp voert zelf PASE,
attestation, fabric/NOC, CASE en de inspectie van de endpoints uit. Bij een bridge worden alle
gevonden endpoints toegevoegd; Apple's ene gekozen naam wordt alleen gebruikt wanneer er ook echt
één Stulp-apparaat uit kwam, en de gekozen kamer is de Stulp-ruimte met die naam. Elke stap
verschijnt live in de app en op de console van Stulp (`POST /api/stulp/log`).

Voor lokaal HTTP staat alleen `NSAllowsLocalNetworking` aan; er is geen brede ATS-uitzondering.
Gebruik buiten een vertrouwd netwerk altijd HTTPS met een certificaat dat de iPhone vertrouwt.

Een Thread-apparaat werkt alleen wanneer iOS toegang heeft tot het gekozen standaard
Thread-netwerk én Stulp dat netwerk via een permanente border router kan bereiken. Dat is
doorgaans een Apple TV of HomePod; een andere border router werkt alleen als iOS de gegevens van
hetzelfde Thread-netwerk kent. De iPhone is de commissioner, niet de blijvende router. Meer in
[`../docs/matter.md`](../docs/matter.md).

## Icoon

Het icoon komt uit de centrale export in `~/Pictures/logo` (zie [`../Branding/README.md`](../Branding/README.md));
de PNG's in `Sources/Stulp/Assets.xcassets/AppIcon.appiconset` zijn daarvan afgeleid: iOS met
dekkende achtergrond, een donkere en een getinte (grijswaarden) variant, en de Mac-formaten met
transparante hoeken. De accentkleur is het roze van het huis in het icoon (`#FF00A8`; licht
`#EB009B` voor leesbare tekst op wit, donker `#FF2EB4`).

`~/Pictures/logo/catalog.json` wijst voor Stulp nog naar `stulp/ios/StulpApp/Assets.xcassets` en
heeft een `web`-regel voor de verwijderde webinterface. Zet daar `"apple":
"stulp/apple/Sources/Stulp/Assets.xcassets"` en haal `web` en `webIconPrefix` weg voordat je
opnieuw exporteert; anders schrijft de uitrol naar het oude pad en zet hij de webiconen terug.
