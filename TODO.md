# CinePlanner — TODO

Wat nog open staat. Afgerond werk staat in de git-geschiedenis (de commitberichten, en eerdere versies van dit bestand).
Omvang: (S) klein, (M) middel, (L) groot. Is iets klaar, haal het dan weg.

## Volgende release: wat CineStager nu meestuurt

CineStager 6.3 stuurt nieuwe gegevens mee met elke opname. Wat ze betekenen en waar ze staan, staat onderaan onder **Naslag**. Oudere opnames hebben ze niet: steeds terugvallen op wat er was.

Gebouwd (oktober 2026): camerahoogte boven de vloer, framelines alleen nog een echte verhouding, een map per verdieping (`Scene.sceneMapFloor`, `ShotReference.mapLocationFloor`), diafragma/T-stop/focus op de referentie (kaart, PDF, HTML, webpagina), plek en noorden op de scene map (`SunSettings.backgroundNorthDeg`, vast zoals bij een satellietkaart en meedraaiend met de achtergrond; bij een andere plek eerst vragen), de beeldhoek-wig met squeeze en rear-adapter, en maps die later komen (een balk in het CineStager-importvenster). Unit tests in `CineStagerGeographyTests`.

**Op een toestel testen**

- [x] Een CineStager-opname met camerahoogte boven de vloer importeren: klopt de hoogte ("Camera Height" op de referentiekaart)?
- [x] Een locatie met verdiepingen: een opname op de eerste verdieping in een scène met de map van de begane grond geeft de vraag om de map te vervangen (met de verdieping erin); in een batch komen de markers alleen op de map van hun eigen verdieping
- [x] Game mode met scherptediepte: T-stop, f-getal en focus op de referentiekaart, onder de foto in de PDF en in het bijschrift in de HTML-export en op de webpagina
- [x] Plek en noorden: het adres, de tijdzone en het kompas na importeren; het noorden vast in het zon-venster; meedraaien met het uitlijngereedschap; de vraag bij een scène die al een andere plek heeft
- [x] Een anamorfe opname: de wig breed genoeg (zoals CineStager's beeldhoek), ook met een rear-adapter
- [x] Link Location in CineStager bij een opname die al in CinePlanner staat: de balk "CineStager has made maps…" in het importvenster, de map op de referentie en desgewenst op de scene map

**Afmaken en testen**

- [x] (M) Personen uit CineStager op een toestel testen: bij een foto personages waar ze stonden; bij een video een personage per standpunt met pijlen ertussen, één naam per persoon
- [x] (S) Een video uit CineStager importeren op een toestel testen: een cameramarker per standpunt, pijlen ertussen (staat in `main`)

## Bij elk nieuw veld

Niet vergeten, anders gaat het mis bij synchroniseren of delen:

- optioneel of met een standaardwaarde (SwiftData met CloudKit)
- mee in delen: `ProjectRecords` (en de test tegen het live schema)
- het `.cineplan`-archief (`ProjectArchive`), en `duplicate()` bij dupliceren
- de exports: PDF, HTML en de webpagina
- vóór een TestFlight- of App Store-build de CloudKit-schema's naar Production:
  - van de eigen container `iCloud.YannickGiraud.CinePlanner`
  - en van de Sharing-container: Mac-debugbuild ▸ Settings ▸ Account ▸ "Prepare iCloud Schema for Sharing", dan in de CloudKit Console Development → Production

## Release

- [ ] Nieuwe velden (oktober 2026): `ShotReference` — `fNumber`, `tStop`, `focusDistance`, `horizontalFOV`, `anamorphicSqueeze`, `anamorphicAdapter`, `mapLocationFloor`, `mapLocationFloorName`; `Scene` — `sceneMapFloor`. Vóór TestFlight/App Store de CloudKit-schema's naar Production (zie "Bij elk nieuw veld")

- [ ] Versie: het project staat op 2.1 (build 9), de eerste versie met delen, en daarna zijn er commits bijgekomen
  - is 2.1 al uitgebracht: een nieuwe versie met een hoger buildnummer
  - zo niet: bij het indienen een notitie voor App Review over het testen van delen (twee Apple ID's)
- [ ] Testen op de Mac, de iPhone en de iPad (de echte iPad: de store in de simulator is leeg)
- [ ] "What's New" en de website: wat er van CineStager nu meekomt (diafragma, focus, camerahoogte, zon en noorden, verdiepingen, personen, video's)
- [ ] Samen uitbrengen met CineStager 6.3, dat deze gegevens meestuurt

## Later

- [ ] (S) De oude mediavelden van `Shot` (`photo1Data`, `photo2Data`, `videoDataLegacy` en de `photo1…`/`photo2…`-details) uit het model halen. `LegacyMediaSweep` zet ze sinds build 7 om; een lichte migratie volstaat
- [ ] (S) Idee: de naam van een mannequin uit CineStager (er zijn acht personen) meenemen als naam van het personage op de scene map. Dan moet CineStager die naam ook meesturen

## Naslag: wat CineStager meestuurt en hoe je het leest

### Waar het staat

In de iCloud-container van CineStager, `iCloud.YannickGiraud.CinemaAR`, map `Documents/` (op de Mac: `~/Library/Mobile Documents/iCloud~YannickGiraud~CinemaAR/Documents/`):

- `shots.json`: een lijst van opnames (in CineStager `ShotItem`, in CinePlanner gelezen in `CineStagerLibrary.swift`). Alle nieuwe velden zijn optioneel en ontbreken als ze niet van toepassing zijn of bij oudere opnames
- `ShotLibrary/CineStager_<id>.jpg`: de foto, met EXIF
- `ShotLibrary/<id>.mp4`: de video. Geen van de velden hieronder: voor een video alles uit shots.json en zijn map halen
- `ShotLibrary/topdown_<id>.jpg`: de map met markers, met EXIF (in CinePlanner gelezen in `CineStagerMapMetadata.swift` en `EXIFExtractor.swift`)
- `ShotLibrary/cleanmap_<id>.jpg`: de schone map (alleen de locatie), zonder EXIF. Hij ligt net zo als de map, dus het noorden van de map geldt ook hiervoor

Het EXIF-gebruikerscommentaar (`UserComment`) bestaat uit velden gescheiden door " | ", elk `Sleutel:Waarde`; splitsen op de eerste ":". Het is ASCII: tekens als ° worden "?" en accenten verdwijnen. Sommige getallen hebben een eenheid erachter ("110.2cm", "3.25m").

Op de map zijn posities genormaliseerd (0…1, oorsprong linksboven) en hoeken in graden met de klok mee vanaf boven (0 = omhoog, 90 = rechts), zoals bij `CameraMapRot`.

### Camerahoogte

- shots.json `cameraHeightAboveFloorCM` (getal, cm). Bij foto's; bij een video alleen als de locatie er later met Link Location aan gekoppeld is. Anders staat hij voor een video alleen in de EXIF van zijn map
- EXIF van de foto en de map: `Camera Height Above Floor:110.2cm`. Bij een video: waar de camera begon
- Betekenis: hoe hoog de camera boven de vloer stond, bij een locatie met verdiepingen boven de verdieping waar hij op stond (zie Verdieping). Alleen met een locatie in de scène
- Opnames van vóór 6.3 meten vanaf de actieve verdieping; in Game mode is dat de begane grond, ook als de camera boven een hogere verdieping hing
- Niet gebruiken als camerahoogte: `heightCM` / `Height`. In AR is dat de hoogte ten opzichte van waar de AR-sessie begon; in Game mode is het leeg

### Diafragma en focus

- shots.json:
  - `fNumber` (getal): het f-getal, de opening
  - `tStop` (getal): het T-getal zoals een cinelens het aangeeft; leeg bij een lens in f-stops
  - `focusDistanceM` (getal, meter): de afstand waarop is scherpgesteld. Altijd eindig; op de achtergrond kan het honderden meters zijn
- EXIF van de foto:
  - de standaardvelden `FNumber` (= `fNumber`) en `SubjectDistance` (= de focusafstand, meter)
  - in het commentaar `F-Number:2.8`, `T-Stop:3.1` en `Focus Distance:3.25m`
  - in het bijschrift "T3.1 (f/2.8) • Focus 3.2 m"
- Alleen bij Game mode met scherptediepte aan (de F-knop). Bij een video: zoals het stond toen de opname begon
- Tonen: met een T-stop "T3.1" (eventueel met "f/2.8" erbij), anders "f/2.8"; de focus als "3.2 m"
- Niet verwarren met `subjectDistanceM` in shots.json: dat is de afstand van de camera tot de dichtstbijzijnde mannequin, voor het schatten van de shotgrootte
- Foto's van een echte camera hebben vaak ook `FNumber` en `SubjectDistance`, met dezelfde betekenis

### Beeldhoek en lens

- shots.json `horizontalFOVDegrees` (getal, graden); EXIF van de foto `Horizontal FOV:56.74` (graden, zonder teken)
- Betekenis: de volledige horizontale beeldhoek van het opgenomen formaat (het hele sensorgebied, niet de framelines-uitsnede), ontknepen: bij anamorf zoveel breder als de squeeze, en een rear-adapter is meegerekend. Voorbeeld: Alexa Mini LF 4.3K LF 16:9 (35,6 mm breed), 33 mm → 56,74°
- Gebruik: direct als hoek van de beeldhoek-wig
- Voor oudere opnames zelf uitrekenen: 2 · atan(`sensorWidthMM` · S / (2 · `focalLengthMM` · k)), met S = `anamorphicSqueeze` (1 als die ontbreekt) en k = de factor van een rear-adapter (het getal in `anamorphicAdapter` als die op "rear" eindigt), anders 1
- De lens in shots.json:
  - `anamorphicSqueeze` (getal): de totale squeeze van lens en adapter samen; leeg bij een sferische lens
  - `anamorphicAdapter` (tekst): bv. "1.33× front" of "2× rear"; leeg zonder adapter. Een rear-adapter maakt ook de brandpuntsafstand zoveel langer
  - `sensorWidthMM`, `sensorHeightMM` (mm): het opgenomen sensorgebied van het formaat, zoals het op de sensor ligt (geknepen)
  - `focalLengthMM` (geheel getal, mm): de brandpuntsafstand zoals op de lens, zonder adapter

### Plek

- shots.json `locationPlace`:
  - `latitude`, `longitude` (getallen): graden, decimaal, WGS84; noord en oost positief
  - `timeZoneIdentifier` (tekst): een IANA-tijdzone, bv. "Europe/Amsterdam"
  - `name` (tekst): het adres zoals het in CineStager is gevonden, volledig en met accenten
- EXIF van de map: `Location Latitude:52.366033`, `Location Longitude:4.916792`, `Location Time Zone:Europe/Amsterdam` en `Location Place:…` (de naam zonder accenten, want de EXIF is ASCII; liever de naam uit shots.json)
- Naar `SunSettings`: `address` = de naam, `latitude`, `longitude`, `timeZoneID` = de tijdzone
- Alleen als de locatie een plek heeft. Bij nieuwe locaties is dat altijd zo; bij oudere misschien niet

### Noorden

- shots.json `mapNorth` (getal); EXIF van de map `MapNorth:14.0`
- Betekenis: de richting van het noorden op de map, in graden met de klok mee vanaf de bovenkant van het beeld: 0 = het noorden ligt boven, 90 = rechts. Het geldt voor de map en de schone map
- Naar `SunSettings.northOffsetDeg` (de schermhoek vanaf boven, met de klok mee, die naar het noorden wijst): gelijk aan `mapNorth`. Is de achtergrond gedraaid (`sceneMapBackgroundRotation`, ook met de klok mee), dan die draaiing erbij optellen
- Ter vergelijking: bij een satellietkaart is het `-heading`. Een CineStager-map werkt net zo, met heading = `-mapNorth`
- Het komt uit de locatie: CineStager slaat per locatie op waar het noorden op het plan ligt, en de map ligt recht op dat plan. Voorbeeld: locatie Kelder heeft het noorden op 14° → `MapNorth:14.0`
- Alleen als bij de locatie het noorden is ingesteld

### Verdieping

- shots.json `floor` (geheel getal) en `floorName` (tekst); EXIF van de map `Location Floor:1` en `Location Floor Name:Floor 1`
- Betekenis: de verdieping waar de camera op stond (bij een video: waar hij begon). Het is de hoogste ingestelde verdieping op of onder de camera
- Nummering: 0 is de laagste verdieping die in CineStager is ingesteld, en heet altijd "Ground"; daarna "Floor 1", "Floor 2", … De namen zijn vast, niet door de gebruiker gekozen, en "Ground" kan dus ook een kelder zijn
- Alleen bij een locatie met meer dan één verdieping
- Gebruik: `locationModelName` + `floor` als sleutel voor "dezelfde map". Bij opnames zonder `floor` (één verdieping, of van vóór 6.3) alleen de naam
- Let op: welke verdieping de map laat zien, hangt ook af van de mannequins. CineStager knipt verdiepingen weg die een mannequin verbergen; zonder mannequins wordt niets weggeknipt. Twee maps van dezelfde locatie en verdieping zijn dus meestal, maar niet altijd, gelijk

### Overig

- `mode`: "ar" of "game"
- `captureID`: koppelt de foto of video aan zijn map; staat in de EXIF van beide als `CaptureID`
