# App-iconen

De bewerkbare bron staat centraal in ~/Pictures/logo/icons/; catalog.json koppelt appnamen aan deze assetcatalogs. Deze Branding-map bevat een kopie voor het project. Wijzig het ontwerp in de bronmap en exporteer opnieuw.

De PNG-assets zijn afgeleid van die SVG's. iOS heeft een volledig dekkende achtergrond; macOS transparante buitenhoeken. De getinte variant is grijswaarden. tvOS gebruikt een dekkende achterlaag en een transparante voorlaag, plus de bestaande top-shelf-formaten.

De oudere make-icon/make-scad-icon/make-print-icon/make-art-generators tekenen de vorige ontwerpen en zijn niet de bron van deze iconen. Gebruik voor iconen de centrale export. Accentkleuren en overige artwork blijven in het project beheerd.

Opnieuw exporteren en toepassen vanuit ~/Pictures/logo:

    python3 tools/build_svg.py
    node tools/render_preview.cjs
    node tools/export_apps.cjs ~/Git/haas.software
    python3 tools/apply_rollout.py --apply

De Node-tools gebruiken sharp (of SHARP_MODULE). De uitrol controleert bestandsversies en bewaart backups. Het vervangen van deze bronnen publiceert geen nieuwe appversie; een reguliere build/release is daarna nodig.
