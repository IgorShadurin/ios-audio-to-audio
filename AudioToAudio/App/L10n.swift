import Foundation

enum L10n {
    static func tr(_ key: String) -> String {
        if let override = manualOverride(for: key) {
            return override
        }

        for locale in preferredLocalizationKeys() {
            if let value = localizedValue(for: key, locale: locale) {
                return value
            }
        }

        return NSLocalizedString(key, comment: "")
    }

    static func fmt(_ key: String, _ args: CVarArg...) -> String {
        String(format: tr(key), locale: .current, arguments: args)
    }

    private static let stringsLinePattern = #"^\s*"((?:\\.|[^"])*)"\s*=\s*"((?:\\.|[^"])*)";\s*$"#
    private static let stringsLineRegex = try? NSRegularExpression(pattern: stringsLinePattern, options: [])
    private static var localizedCache: [String: [String: String]] = [:]
    private static let localizedCacheLock = NSLock()

    private static func manualOverride(for key: String) -> String? {
        guard let languageKey = resolvedLanguageKey() else {
            return nil
        }

        switch key {
        case "app.title":
            return appTitleOverrides[languageKey]
        case "Premium Active":
            return localizedValue(for: "Premium active: unlimited usage.", locale: languageKey)
                ?? localizedValue(for: "Premium", locale: languageKey)
        case "source.title":
            return sourceTitleOverrides[languageKey]
        case "source.subtitle":
            return sourceSubtitleOverrides[languageKey]
        case "status.pick_source":
            return pickSourceOverrides[languageKey]
        case "status.loading_source":
            return readingMetadataOverrides[languageKey]
        case "status.cancelling":
            return cancellingOverrides[languageKey]
        case "error.no_source_selected":
            return pickSourceOverrides[languageKey]
        case "action.apply":
            return continueOverrides[languageKey]
        case "action.pick_photos":
            return pickPhotosOverrides[languageKey]
        case "action.pick_files":
            return pickFilesOverrides[languageKey]
        case "action.back":
            return localizedValue(for: "Go back", locale: languageKey)
        case "action.reset":
            return localizedValue(for: "Reset", locale: languageKey)
        case "action.new_trim":
            return localizedValue(for: "Start over", locale: languageKey)
                ?? localizedValue(for: "New video", locale: languageKey)
        case "action.suggest_boundaries":
            return suggestBoundariesOverrides[languageKey]
        case "action.cancel_trim":
            return cancelTrimOverrides[languageKey]
        case "action.cancelling":
            return cancellingOverrides[languageKey]
        case "trim.optimize_network":
            return optimizeNetworkOverrides[languageKey]
        case "action.share_audio":
            return helpResultComponent(languageKey: languageKey, index: 1)
        case "action.save_files":
            return helpResultComponent(languageKey: languageKey, index: 2)
        case "result.ready":
            return helpResultComponent(languageKey: languageKey, index: 0)
        case "help.result.message":
            return helpResultMessageOverrides[languageKey]
        case "status.reading_metadata":
            return readingMetadataOverrides[languageKey]
        case "trim.preset":
            return trimPresetOverrides[languageKey]
        case "trim.fade_in_value":
            return trimFadeInValueOverrides[languageKey]
        case "trim.fade_out_value":
            return trimFadeOutValueOverrides[languageKey]
        case "summary.plan":
            return summaryPlanOverrides[languageKey]
        case "trim.set_end":
            return trimSetEndOverrides[languageKey]
        case "action.continue":
            return continueOverrides[languageKey]
        default:
            return nil
        }
    }

    private static func resolvedLanguageKey() -> String? {
        for locale in preferredLocalizationKeys() {
            if appTitleOverrides[locale] != nil || trimSetEndOverrides[locale] != nil || continueOverrides[locale] != nil {
                return locale
            }

            if let languageCode = locale.split(separator: "-").first.map(String.init),
               appTitleOverrides[languageCode] != nil || trimSetEndOverrides[languageCode] != nil || continueOverrides[languageCode] != nil {
                return languageCode
            }
        }

        return nil
    }

    private static func preferredLocalizationKeys() -> [String] {
        var keys: [String] = []

        func append(_ rawValue: String?) {
            guard let rawValue else { return }
            let normalized = rawValue.replacingOccurrences(of: "_", with: "-")
            guard !normalized.isEmpty else { return }

            if !keys.contains(normalized) {
                keys.append(normalized)
            }

            let segments = normalized.split(separator: "-").map(String.init)
            guard segments.count > 1 else { return }

            for index in stride(from: segments.count - 1, through: 1, by: -1) {
                let fallback = segments.prefix(index).joined(separator: "-")
                if !keys.contains(fallback) {
                    keys.append(fallback)
                }
            }
        }

        Bundle.main.preferredLocalizations.forEach(append)
        append(Locale.current.identifier)
        append(Locale.current.language.languageCode?.identifier)
        append(Bundle.main.developmentLocalization)
        append("en")

        return keys
    }

    private static func localizedValue(for key: String, locale: String) -> String? {
        localizedCacheLock.lock()
        if let cached = localizedCache[locale] {
            localizedCacheLock.unlock()
            return cached[key]
        }
        localizedCacheLock.unlock()

        guard let bundlePath = Bundle.main.path(forResource: locale, ofType: "lproj"),
              let stringsPath = Bundle(path: bundlePath)?.path(forResource: "Localizable", ofType: "strings"),
              let contents = try? String(contentsOfFile: stringsPath, encoding: .utf8)
        else {
            localizedCacheLock.lock()
            localizedCache[locale] = [:]
            localizedCacheLock.unlock()
            return nil
        }

        var parsed: [String: String] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            let rawLine = String(line)
            let fullRange = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
            guard let match = stringsLineRegex?.firstMatch(in: rawLine, options: [], range: fullRange),
                  match.numberOfRanges == 3,
                  let keyRange = Range(match.range(at: 1), in: rawLine),
                  let valueRange = Range(match.range(at: 2), in: rawLine)
            else {
                continue
            }

            let parsedKey = unescape(rawLine[keyRange])
            let parsedValue = unescape(rawLine[valueRange])
            if parsed[parsedKey] == nil {
                // Keep first occurrence so later duplicate fallback lines do not override localized values.
                parsed[parsedKey] = parsedValue
            }
        }

        localizedCacheLock.lock()
        localizedCache[locale] = parsed
        localizedCacheLock.unlock()

        return parsed[key]
    }

    private static func unescape<S: StringProtocol>(_ value: S) -> String {
        String(value)
            .replacingOccurrences(of: #"\""#, with: "\"")
            .replacingOccurrences(of: #"\\\\"#, with: "\\")
    }

    private static func helpResultComponent(languageKey: String, index: Int) -> String? {
        guard let message = helpResultMessageOverrides[languageKey] else {
            return nil
        }
        let parts = message.split(separator: "•").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.indices.contains(index) else {
            return nil
        }
        return parts[index]
    }

    private static let continueOverrides: [String: String] = [
        "ar": "متابعة",
        "bg": "Напред",
        "ca": "Continua",
        "cs": "Pokračovat",
        "da": "Fortsæt",
        "de": "Weiter",
        "el": "Συνέχεια",
        "en": "Continue",
        "es": "Continuar",
        "fi": "Jatka",
        "fr": "Continuer",
        "he": "המשך",
        "hi": "जारी रखें",
        "hr": "Nastavi",
        "hu": "Folytatás",
        "id": "Lanjutkan",
        "it": "Continua",
        "ja": "続ける",
        "ko": "계속",
        "ms": "Teruskan",
        "nb": "Fortsett",
        "nl": "Ga door",
        "no": "Fortsett",
        "pl": "Dalej",
        "pt": "Continuar",
        "ro": "Continuă",
        "ru": "Далее",
        "sk": "Pokračovať",
        "sv": "Fortsätt",
        "th": "ต่อไป",
        "tr": "Devam",
        "uk": "Далі",
        "vi": "Tiếp tục",
        "zh-Hans": "继续",
        "zh-Hant": "繼續"
    ]

    private static let trimSetEndOverrides: [String: String] = [
        "ar": "نقطة النهاية",
        "bg": "Край",
        "ca": "Punt final",
        "cs": "Konec",
        "da": "Slutpunkt",
        "de": "Endpunkt",
        "el": "Τέλος",
        "en": "End Point",
        "es": "Punto final",
        "fi": "Loppu",
        "fr": "Fin",
        "he": "נקודת סיום",
        "hi": "समाप्ति",
        "hr": "Kraj",
        "hu": "Végpont",
        "id": "Titik akhir",
        "it": "Punto finale",
        "ja": "終了位置",
        "ko": "끝 지점",
        "ms": "Titik akhir",
        "nb": "Sluttpunkt",
        "nl": "Eindpunt",
        "no": "Sluttpunkt",
        "pl": "Punkt końca",
        "pt": "Ponto final",
        "ro": "Punct final",
        "ru": "Конец",
        "sk": "Koniec",
        "sv": "Slutpunkt",
        "th": "จุดสิ้นสุด",
        "tr": "Bitiş noktası",
        "uk": "Кінець",
        "vi": "Điểm kết thúc",
        "zh-Hans": "结束点",
        "zh-Hant": "結束點"
    ]

    private static let appTitleOverrides: [String: String] = [
        "ar": "من صوت إلى صوت",
        "bg": "Аудио към Аудио",
        "ca": "Àudio a Àudio",
        "cs": "Audio na Audio",
        "da": "Lyd til Lyd",
        "de": "Audio zu Audio",
        "el": "Ήχος σε Ήχο",
        "en": "Audio To Audio",
        "es": "Audio a Audio",
        "fi": "Ääni Ääneksi",
        "fr": "Audio vers Audio",
        "he": "מאודיו לאודיו",
        "hi": "ऑडियो से ऑडियो",
        "hr": "Audio u Audio",
        "hu": "Hangból Hang",
        "id": "Audio ke Audio",
        "it": "Audio in Audio",
        "ja": "音声から音声へ",
        "ko": "오디오를 오디오로",
        "ms": "Audio ke Audio",
        "nb": "Lyd til Lyd",
        "nl": "Audio naar Audio",
        "no": "Lyd til Lyd",
        "pl": "Audio na Audio",
        "pt": "Áudio para Áudio",
        "ro": "Audio în Audio",
        "ru": "Аудио в Аудио",
        "sk": "Audio na Audio",
        "sv": "Ljud till Ljud",
        "th": "เสียงเป็นเสียง",
        "tr": "Sesten Sese",
        "uk": "Аудіо в Аудіо",
        "vi": "Âm thanh sang Âm thanh",
        "zh-Hans": "音频转音频",
        "zh-Hant": "音訊轉音訊"
    ]

    private static let sourceTitleOverrides: [String: String] = [
        "ar": "طريقة الاستيراد",
        "bg": "Метод на импортиране",
        "ca": "Mètode d'importació",
        "cs": "Metoda importu",
        "da": "Importmetode",
        "de": "Importmethode",
        "el": "Μέθοδος εισαγωγής",
        "en": "Import Method",
        "es": "Método de importación",
        "fi": "Tuontitapa",
        "fr": "Méthode d'importation",
        "he": "שיטת ייבוא",
        "hi": "आयात विधि",
        "hr": "Način uvoza",
        "hu": "Importálási mód",
        "id": "Metode Impor",
        "it": "Metodo di importazione",
        "ja": "読み込み方法",
        "ko": "가져오기 방법",
        "ms": "Kaedah Import",
        "nb": "Importmetode",
        "nl": "Importmethode",
        "no": "Importmetode",
        "pl": "Metoda importu",
        "pt": "Método de importação",
        "ro": "Metodă de import",
        "ru": "Способ импорта",
        "sk": "Metóda importu",
        "sv": "Importmetod",
        "th": "วิธีนำเข้า",
        "tr": "İçe aktarma yöntemi",
        "uk": "Спосіб імпорту",
        "vi": "Phương thức nhập",
        "zh-Hans": "导入方式",
        "zh-Hant": "匯入方式"
    ]

    private static let sourceSubtitleOverrides: [String: String] = [
        "ar": "«الصور» فيديو فقط. «الملفات» صوت أو فيديو.",
        "bg": "«Снимки» само видео. «Файлове» аудио или видео.",
        "ca": "«Fotos» només vídeo. «Fitxers» àudio o vídeo.",
        "cs": "«Fotky» jen video. «Soubory» audio nebo video.",
        "da": "«Fotos» kun video. «Filer» lyd eller video.",
        "de": "«Fotos» nur Video. «Dateien» Audio oder Video.",
        "el": "«Φωτογραφίες» μόνο βίντεο. «Αρχεία» ήχος ή βίντεο.",
        "en": "«Photos» video only. «Files» audio or video.",
        "es": "«Fotos» solo video. «Archivos» audio o video.",
        "fi": "«Kuvat» vain video. «Tiedostot» ääni tai video.",
        "fr": "«Photos» vidéo uniquement. «Fichiers» audio ou vidéo.",
        "he": "«תמונות» וידאו בלבד. «קבצים» שמע או וידאו.",
        "hi": "«फ़ोटो» केवल वीडियो। «फ़ाइलें» ऑडियो या वीडियो।",
        "hr": "«Fotografije» samo video. «Datoteke» audio ili video.",
        "hu": "«Fotók» csak videó. «Fájlok» hang vagy videó.",
        "id": "«Foto» hanya video. «File» audio atau video.",
        "it": "«Foto» solo video. «File» audio o video.",
        "ja": "«写真» 動画のみ。«ファイル» 音声または動画。",
        "ko": "«사진» 동영상만. «파일» 오디오 또는 동영상.",
        "ms": "«Foto» video sahaja. «Fail» audio atau video.",
        "nb": "«Bilder» kun video. «Filer» lyd eller video.",
        "nl": "«Foto's» alleen video. «Bestanden» audio of video.",
        "no": "«Bilder» kun video. «Filer» lyd eller video.",
        "pl": "«Zdjęcia» tylko wideo. «Pliki» audio lub wideo.",
        "pt": "«Fotos» somente vídeo. «Arquivos» áudio ou vídeo.",
        "ro": "«Poze» doar video. «Fișiere» audio sau video.",
        "ru": "«Фото» только видео. «Файлы» аудио или видео.",
        "sk": "«Fotky» iba video. «Súbory» audio alebo video.",
        "sv": "«Bilder» endast video. «Filer» ljud eller video.",
        "th": "«รูปภาพ» วิดีโอเท่านั้น. «ไฟล์» เสียงหรือวิดีโอ.",
        "tr": "«Fotoğraflar» yalnızca video. «Dosyalar» ses veya video.",
        "uk": "«Фото» лише відео. «Файли» аудіо або відео.",
        "vi": "«Ảnh» chỉ video. «Tệp» âm thanh hoặc video.",
        "zh-Hans": "«照片» 仅视频。«文件» 音频或视频。",
        "zh-Hant": "«照片» 僅影片。«檔案» 音訊或影片。"
    ]

    private static let pickSourceOverrides: [String: String] = [
        "ar": "اختر من «الملفات»، صوت أو فيديو، أو من «الصور»، فيديو فقط.",
        "bg": "Изберете от «Файлове», аудио или видео, или от «Снимки», само видео.",
        "ca": "Tria de «Fitxers», àudio o vídeo, o de «Fotos», només vídeo.",
        "cs": "Vyberte ze «Souborů», audio nebo video, nebo z «Fotek», jen video.",
        "da": "Vælg fra «Filer», lyd eller video, eller «Fotos», kun video.",
        "de": "Wählen Sie aus «Dateien», Audio oder Video, oder «Fotos», nur Video.",
        "el": "Επιλέξτε από «Αρχεία», ήχος ή βίντεο, ή από «Φωτογραφίες», μόνο βίντεο.",
        "en": "Choose «Files» for audio or video, or «Photos» for video only.",
        "es": "Elija de «Archivos», audio o video, o de «Fotos», solo video.",
        "fi": "Valitse «Tiedostot», ääni tai video, tai «Kuvat», vain video.",
        "fr": "Choisissez dans «Fichiers», audio ou vidéo, ou «Photos», vidéo uniquement.",
        "he": "בחר מ«קבצים», שמע או וידאו, או מ«תמונות», וידאו בלבד.",
        "hi": "«फ़ाइलें» से चुनें, ऑडियो या वीडियो, या «फ़ोटो» से, केवल वीडियो।",
        "hr": "Odaberite iz «Datoteka», audio ili video, ili iz «Fotografija», samo video.",
        "hu": "Válasszon a «Fájlokból», hang vagy videó, vagy a «Fotókból», csak videó.",
        "id": "Pilih dari «File», audio atau video, atau «Foto», hanya video.",
        "it": "Scegli da «File», audio o video, o da «Foto», solo video.",
        "ja": "«ファイル» から選択、音声または動画。 または «写真» から選択、動画のみ。",
        "ko": "«파일»에서 선택, 오디오 또는 동영상. 또는 «사진»에서 선택, 동영상만.",
        "ms": "Pilih daripada «Fail», audio atau video, atau «Foto», video sahaja.",
        "nb": "Velg fra «Filer», lyd eller video, eller «Bilder», kun video.",
        "nl": "Kies uit «Bestanden», audio of video, of «Foto's», alleen video.",
        "no": "Velg fra «Filer», lyd eller video, eller «Bilder», kun video.",
        "pl": "Wybierz z «Plików», audio lub wideo, albo ze «Zdjęć», tylko wideo.",
        "pt": "Escolha em «Arquivos», áudio ou vídeo, ou «Fotos», somente vídeo.",
        "ro": "Alegeți din «Fișiere», audio sau video, sau din «Poze», doar video.",
        "ru": "Выберите в «Файлах», аудио или видео, или в «Фото», только видео.",
        "sk": "Vyberte zo «Súborov», audio alebo video, alebo z «Fotiek», iba video.",
        "sv": "Välj från «Filer», ljud eller video, eller «Bilder», endast video.",
        "th": "เลือกจาก «ไฟล์» เสียงหรือวิดีโอ หรือจาก «รูปภาพ» วิดีโอเท่านั้น.",
        "tr": "«Dosyalar»dan seçin, ses veya video, ya da «Fotoğraflar»dan seçin, yalnızca video.",
        "uk": "Оберіть у «Файлах», аудіо або відео, або у «Фото», лише відео.",
        "vi": "Chọn từ «Tệp», âm thanh hoặc video, hoặc từ «Ảnh», chỉ video.",
        "zh-Hans": "从 «文件» 选择，音频或视频，或从 «照片» 选择，仅视频。",
        "zh-Hant": "從 «檔案» 選擇，音訊或影片，或從 «照片» 選擇，僅影片。"
    ]

    private static let pickPhotosOverrides: [String: String] = [
        "ar": "اختر من «الصور»",
        "bg": "Избери от «Снимки»",
        "ca": "Tria de «Fotos»",
        "cs": "Vyber z «Fotek»",
        "da": "Vælg fra «Fotos»",
        "de": "Aus «Fotos» wählen",
        "el": "Επιλογή από «Φωτογραφίες»",
        "en": "Pick from «Photos»",
        "es": "Elegir de «Fotos»",
        "fi": "Valitse «Kuvista»",
        "fr": "Choisir dans «Photos»",
        "he": "בחר מתוך «תמונות»",
        "hi": "«फ़ोटो» से चुनें",
        "hr": "Odaberi iz «Fotografija»",
        "hu": "Válassz a «Fotók» közül",
        "id": "Pilih dari «Foto»",
        "it": "Scegli da «Foto»",
        "ja": "«写真» から選択",
        "ko": "«사진»에서 선택",
        "ms": "Pilih dari «Foto»",
        "nb": "Velg fra «Bilder»",
        "nl": "Kies uit «Foto's»",
        "no": "Velg fra «Bilder»",
        "pl": "Wybierz z «Zdjęć»",
        "pt": "Escolher de «Fotos»",
        "ro": "Alege din «Poze»",
        "ru": "Выбрать из «Фото»",
        "sk": "Vyber z «Fotiek»",
        "sv": "Välj från «Bilder»",
        "th": "เลือกจาก «รูปภาพ»",
        "tr": "«Fotoğraflar»dan seç",
        "uk": "Вибрати з «Фото»",
        "vi": "Chọn từ «Ảnh»",
        "zh-Hans": "从 «照片» 选择",
        "zh-Hant": "從 «照片» 選擇"
    ]

    private static let pickFilesOverrides: [String: String] = [
        "ar": "اختر من «الملفات»",
        "bg": "Избери от «Файлове»",
        "ca": "Tria de «Fitxers»",
        "cs": "Vyber ze «Souborů»",
        "da": "Vælg fra «Filer»",
        "de": "Aus «Dateien» wählen",
        "el": "Επιλογή από «Αρχεία»",
        "en": "Pick from «Files»",
        "es": "Elegir de «Archivos»",
        "fi": "Valitse «Tiedostoista»",
        "fr": "Choisir dans «Fichiers»",
        "he": "בחר מתוך «קבצים»",
        "hi": "«फ़ाइलें» से चुनें",
        "hr": "Odaberi iz «Datoteka»",
        "hu": "Válassz a «Fájlok» közül",
        "id": "Pilih dari «File»",
        "it": "Scegli da «File»",
        "ja": "«ファイル» から選択",
        "ko": "«파일»에서 선택",
        "ms": "Pilih dari «Fail»",
        "nb": "Velg fra «Filer»",
        "nl": "Kies uit «Bestanden»",
        "no": "Velg fra «Filer»",
        "pl": "Wybierz z «Plików»",
        "pt": "Escolher de «Arquivos»",
        "ro": "Alege din «Fișiere»",
        "ru": "Выбрать из «Файлов»",
        "sk": "Vyber zo «Súborov»",
        "sv": "Välj från «Filer»",
        "th": "เลือกจาก «ไฟล์»",
        "tr": "«Dosyalar»dan seç",
        "uk": "Вибрати з «Файлів»",
        "vi": "Chọn từ «Tệp»",
        "zh-Hans": "从 «文件» 选择",
        "zh-Hant": "從 «檔案» 選擇"
    ]

    private static let suggestBoundariesOverrides: [String: String] = [
        "ar": "اقتراح حدود نظيفة",
        "bg": "Предложи чисти граници",
        "ca": "Suggerix límits nets",
        "cs": "Navrhnout čisté hranice",
        "da": "Foreslå rene grænser",
        "de": "Saubere Grenzen vorschlagen",
        "el": "Πρότεινε καθαρά όρια",
        "en": "Suggest clean boundaries",
        "es": "Sugerir límites limpios",
        "fi": "Ehdota siistit rajat",
        "fr": "Suggérer des limites propres",
        "he": "הצע גבולות נקיים",
        "hi": "साफ़ सीमाएँ सुझाएँ",
        "hr": "Predloži čiste granice",
        "hu": "Tiszta határok javaslata",
        "id": "Sarankan batas bersih",
        "it": "Suggerisci limiti puliti",
        "ja": "きれいな境界を提案",
        "ko": "깔끔한 경계 제안",
        "ms": "Cadangkan sempadan bersih",
        "nb": "Foreslå rene grenser",
        "nl": "Stel nette grenzen voor",
        "no": "Foreslå rene grenser",
        "pl": "Zaproponuj czyste granice",
        "pt": "Sugerir limites limpos",
        "ro": "Sugerează limite curate",
        "ru": "Предложить чистые границы",
        "sk": "Navrhnúť čisté hranice",
        "sv": "Föreslå rena gränser",
        "th": "แนะนำขอบเขตที่สะอาด",
        "tr": "Temiz sınırlar öner",
        "uk": "Запропонувати чисті межі",
        "vi": "Đề xuất ranh giới sạch",
        "zh-Hans": "建议干净边界",
        "zh-Hant": "建議乾淨邊界"
    ]

    private static let cancelTrimOverrides: [String: String] = [
        "ar": "إلغاء التحويل",
        "bg": "Отказ на конвертиране",
        "ca": "Cancel·la la conversió",
        "cs": "Zrušit převod",
        "da": "Annuller konvertering",
        "de": "Konvertierung abbrechen",
        "el": "Ακύρωση μετατροπής",
        "en": "Cancel conversion",
        "es": "Cancelar conversión",
        "fi": "Peruuta muunnos",
        "fr": "Annuler la conversion",
        "he": "בטל המרה",
        "hi": "रूपांतरण रद्द करें",
        "hr": "Otkaži konverziju",
        "hu": "Átalakítás megszakítása",
        "id": "Batalkan konversi",
        "it": "Annulla conversione",
        "ja": "変換をキャンセル",
        "ko": "변환 취소",
        "ms": "Batal penukaran",
        "nb": "Avbryt konvertering",
        "nl": "Conversie annuleren",
        "no": "Avbryt konvertering",
        "pl": "Anuluj konwersję",
        "pt": "Cancelar conversão",
        "ro": "Anulează conversia",
        "ru": "Отменить конвертацию",
        "sk": "Zrušiť konverziu",
        "sv": "Avbryt konvertering",
        "th": "ยกเลิกการแปลง",
        "tr": "Dönüştürmeyi iptal et",
        "uk": "Скасувати конвертацію",
        "vi": "Hủy chuyển đổi",
        "zh-Hans": "取消转换",
        "zh-Hant": "取消轉換"
    ]

    private static let cancellingOverrides: [String: String] = [
        "ar": "جارٍ الإلغاء...",
        "bg": "Отказване...",
        "ca": "Cancel·lant...",
        "cs": "Ruší se...",
        "da": "Annullerer...",
        "de": "Wird abgebrochen...",
        "el": "Ακύρωση...",
        "en": "Cancelling...",
        "es": "Cancelando...",
        "fi": "Peruutetaan...",
        "fr": "Annulation...",
        "he": "מבטל...",
        "hi": "रद्द किया जा रहा है...",
        "hr": "Otkazivanje...",
        "hu": "Megszakítás...",
        "id": "Membatalkan...",
        "it": "Annullamento...",
        "ja": "キャンセル中...",
        "ko": "취소 중...",
        "ms": "Membatalkan...",
        "nb": "Avbryter...",
        "nl": "Annuleren...",
        "no": "Avbryter...",
        "pl": "Anulowanie...",
        "pt": "Cancelando...",
        "ro": "Se anulează...",
        "ru": "Отмена...",
        "sk": "Ruší sa...",
        "sv": "Avbryter...",
        "th": "กำลังยกเลิก...",
        "tr": "İptal ediliyor...",
        "uk": "Скасування...",
        "vi": "Đang hủy...",
        "zh-Hans": "正在取消...",
        "zh-Hant": "正在取消..."
    ]

    private static let optimizeNetworkOverrides: [String: String] = [
        "ar": "تحسين للاستخدام عبر الشبكة",
        "bg": "Оптимизирай за мрежа",
        "ca": "Optimitza per a ús en xarxa",
        "cs": "Optimalizovat pro síťové použití",
        "da": "Optimer til netværksbrug",
        "de": "Für Netzwerknutzung optimieren",
        "el": "Βελτιστοποίηση για χρήση δικτύου",
        "en": "Optimize for network use",
        "es": "Optimizar para uso en red",
        "fi": "Optimoi verkkokäyttöön",
        "fr": "Optimiser pour l'usage réseau",
        "he": "בצע אופטימיזציה לשימוש ברשת",
        "hi": "नेटवर्क उपयोग के लिए अनुकूलित करें",
        "hr": "Optimiziraj za mrežnu upotrebu",
        "hu": "Optimalizálás hálózati használatra",
        "id": "Optimalkan untuk penggunaan jaringan",
        "it": "Ottimizza per uso in rete",
        "ja": "ネットワーク用に最適化",
        "ko": "네트워크 사용에 최적화",
        "ms": "Optimumkan untuk penggunaan rangkaian",
        "nb": "Optimaliser for nettverksbruk",
        "nl": "Optimaliseren voor netwerkgebruik",
        "no": "Optimaliser for nettverksbruk",
        "pl": "Optymalizuj do użycia w sieci",
        "pt": "Otimizar para uso em rede",
        "ro": "Optimizează pentru utilizare în rețea",
        "ru": "Оптимизировать для сети",
        "sk": "Optimalizovať pre sieťové použitie",
        "sv": "Optimera för nätverksanvändning",
        "th": "ปรับให้เหมาะกับการใช้งานเครือข่าย",
        "tr": "Ağ kullanımı için optimize et",
        "uk": "Оптимізувати для мережі",
        "vi": "Tối ưu cho sử dụng mạng",
        "zh-Hans": "为网络使用优化",
        "zh-Hant": "為網路使用最佳化"
    ]

    private static let readingMetadataOverrides: [String: String] = [
        "ar": "جارٍ قراءة البيانات الوصفية وشكل الموجة...",
        "bg": "Четене на метаданни и форма на вълната...",
        "ca": "S'estan llegint les metadades i la forma d'ona...",
        "cs": "Načítání metadat a průběhu...",
        "da": "Læser metadata og bølgeform...",
        "de": "Metadaten und Wellenform werden gelesen...",
        "el": "Ανάγνωση μεταδεδομένων και κυματομορφής...",
        "en": "Reading metadata and waveform...",
        "es": "Leyendo metadatos y forma de onda...",
        "fi": "Luetaan metatietoja ja aaltomuotoa...",
        "fr": "Lecture des métadonnées et de la forme d'onde...",
        "he": "קורא מטא-נתונים וצורת גל...",
        "hi": "मेटाडेटा और वेवफॉर्म पढ़ा जा रहा है...",
        "hr": "Učitavanje metapodataka i valnog oblika...",
        "hu": "Metaadatok és hullámforma beolvasása...",
        "id": "Membaca metadata dan bentuk gelombang...",
        "it": "Lettura metadati e forma d'onda...",
        "ja": "メタデータと波形を読み込み中...",
        "ko": "메타데이터와 파형을 읽는 중...",
        "ms": "Membaca metadata dan bentuk gelombang...",
        "nb": "Leser metadata og bølgeform...",
        "nl": "Metadata en golfvorm lezen...",
        "no": "Leser metadata og bølgeform...",
        "pl": "Wczytywanie metadanych i przebiegu...",
        "pt": "Lendo metadados e forma de onda...",
        "ro": "Se citesc metadatele și forma de undă...",
        "ru": "Чтение метаданных и формы волны...",
        "sk": "Načítavajú sa metadáta a priebeh...",
        "sv": "Läser metadata och vågform...",
        "th": "กำลังอ่านเมทาดาทาและรูปคลื่น...",
        "tr": "Meta veriler ve dalga biçimi okunuyor...",
        "uk": "Зчитування метаданих і форми хвилі...",
        "vi": "Đang đọc siêu dữ liệu và dạng sóng...",
        "zh-Hans": "正在读取元数据和波形...",
        "zh-Hant": "正在讀取中繼資料和波形..."
    ]

    private static let trimPresetOverrides: [String: String] = [
        "ar": "الإعداد المسبق",
        "bg": "Пресет",
        "ca": "Predefinit",
        "cs": "Předvolba",
        "da": "Forvalg",
        "de": "Voreinstellung",
        "el": "Προεπιλογή",
        "en": "Preset",
        "es": "Preajuste",
        "fi": "Esiasetus",
        "fr": "Préréglage",
        "he": "ערכת מראש",
        "hi": "प्रीसेट",
        "hr": "Predložak",
        "hu": "Előbeállítás",
        "id": "Preset",
        "it": "Predefinito",
        "ja": "プリセット",
        "ko": "프리셋",
        "ms": "Pratetap",
        "nb": "Forhåndsinnstilling",
        "nl": "Voorinstelling",
        "no": "Forhåndsinnstilling",
        "pl": "Ustawienie",
        "pt": "Predefinição",
        "ro": "Preset",
        "ru": "Пресет",
        "sk": "Predvoľba",
        "sv": "Förval",
        "th": "ค่าที่ตั้งไว้",
        "tr": "Ön ayar",
        "uk": "Пресет",
        "vi": "Mẫu sẵn",
        "zh-Hans": "预设",
        "zh-Hant": "預設"
    ]

    private static let trimFadeInValueOverrides: [String: String] = [
        "ar": "تلاشي الدخول: %@",
        "bg": "Плавно усилване: %@",
        "ca": "Entrada suau: %@",
        "cs": "Náběh: %@",
        "da": "Fade ind: %@",
        "de": "Einblenden: %@",
        "el": "Fade in: %@",
        "en": "Fade in: %@",
        "es": "Fundido de entrada: %@",
        "fi": "Häivytys sisään: %@",
        "fr": "Fondu entrant : %@",
        "he": "פייד אין: %@",
        "hi": "फेड इन: %@",
        "hr": "Ulazni fade: %@",
        "hu": "Beúszás: %@",
        "id": "Fade masuk: %@",
        "it": "Dissolvenza in entrata: %@",
        "ja": "フェードイン: %@",
        "ko": "페이드 인: %@",
        "ms": "Fade masuk: %@",
        "nb": "Fade inn: %@",
        "nl": "Fade-in: %@",
        "no": "Fade inn: %@",
        "pl": "Płynne wejście: %@",
        "pt": "Fade de entrada: %@",
        "ro": "Fade in: %@",
        "ru": "Плавное появление: %@",
        "sk": "Nábeh: %@",
        "sv": "Fade in: %@",
        "th": "เฟดเข้า: %@",
        "tr": "Giriş fade: %@",
        "uk": "Плавний вхід: %@",
        "vi": "Fade vào: %@",
        "zh-Hans": "淡入：%@",
        "zh-Hant": "淡入：%@"
    ]

    private static let trimFadeOutValueOverrides: [String: String] = [
        "ar": "تلاشي الخروج: %@",
        "bg": "Плавно затихване: %@",
        "ca": "Sortida suau: %@",
        "cs": "Doznívání: %@",
        "da": "Fade ud: %@",
        "de": "Ausblenden: %@",
        "el": "Fade out: %@",
        "en": "Fade out: %@",
        "es": "Fundido de salida: %@",
        "fi": "Häivytys ulos: %@",
        "fr": "Fondu sortant : %@",
        "he": "פייד אאוט: %@",
        "hi": "फेड आउट: %@",
        "hr": "Izlazni fade: %@",
        "hu": "Kifutás: %@",
        "id": "Fade keluar: %@",
        "it": "Dissolvenza in uscita: %@",
        "ja": "フェードアウト: %@",
        "ko": "페이드 아웃: %@",
        "ms": "Fade keluar: %@",
        "nb": "Fade ut: %@",
        "nl": "Fade-out: %@",
        "no": "Fade ut: %@",
        "pl": "Płynne wyjście: %@",
        "pt": "Fade de saída: %@",
        "ro": "Fade out: %@",
        "ru": "Плавное затухание: %@",
        "sk": "Doznievanie: %@",
        "sv": "Fade out: %@",
        "th": "เฟดออก: %@",
        "tr": "Çıkış fade: %@",
        "uk": "Плавний вихід: %@",
        "vi": "Fade ra: %@",
        "zh-Hans": "淡出：%@",
        "zh-Hant": "淡出：%@"
    ]

    private static let summaryPlanOverrides: [String: String] = [
        "ar": "الإعداد المسبق: %@ • التنسيق: %@ • تلاشي الدخول: %@ • تلاشي الخروج: %@",
        "bg": "Пресет: %@ • Формат: %@ • Плавно усилване: %@ • Плавно затихване: %@",
        "ca": "Predefinit: %@ • Format: %@ • Entrada suau: %@ • Sortida suau: %@",
        "cs": "Předvolba: %@ • Formát: %@ • Náběh: %@ • Doznívání: %@",
        "da": "Forvalg: %@ • Format: %@ • Fade ind: %@ • Fade ud: %@",
        "de": "Voreinstellung: %@ • Format: %@ • Einblenden: %@ • Ausblenden: %@",
        "el": "Προεπιλογή: %@ • Μορφή: %@ • Fade in: %@ • Fade out: %@",
        "en": "Preset: %@ • Format: %@ • Fade in: %@ • Fade out: %@",
        "es": "Preajuste: %@ • Formato: %@ • Fundido de entrada: %@ • Fundido de salida: %@",
        "fi": "Esiasetus: %@ • Muoto: %@ • Häivytys sisään: %@ • Häivytys ulos: %@",
        "fr": "Préréglage : %@ • Format : %@ • Fondu entrant : %@ • Fondu sortant : %@",
        "he": "ערכת מראש: %@ • פורמט: %@ • פייד אין: %@ • פייד אאוט: %@",
        "hi": "प्रीसेट: %@ • फ़ॉर्मेट: %@ • फेड इन: %@ • फेड आउट: %@",
        "hr": "Predložak: %@ • Format: %@ • Ulazni fade: %@ • Izlazni fade: %@",
        "hu": "Előbeállítás: %@ • Formátum: %@ • Beúszás: %@ • Kifutás: %@",
        "id": "Preset: %@ • Format: %@ • Fade masuk: %@ • Fade keluar: %@",
        "it": "Predefinito: %@ • Formato: %@ • Dissolvenza in entrata: %@ • Dissolvenza in uscita: %@",
        "ja": "プリセット: %@ • 形式: %@ • フェードイン: %@ • フェードアウト: %@",
        "ko": "프리셋: %@ • 포맷: %@ • 페이드 인: %@ • 페이드 아웃: %@",
        "ms": "Pratetap: %@ • Format: %@ • Fade masuk: %@ • Fade keluar: %@",
        "nb": "Forhåndsinnstilling: %@ • Format: %@ • Fade inn: %@ • Fade ut: %@",
        "nl": "Voorinstelling: %@ • Formaat: %@ • Fade-in: %@ • Fade-out: %@",
        "no": "Forhåndsinnstilling: %@ • Format: %@ • Fade inn: %@ • Fade ut: %@",
        "pl": "Ustawienie: %@ • Format: %@ • Płynne wejście: %@ • Płynne wyjście: %@",
        "pt": "Predefinição: %@ • Formato: %@ • Fade de entrada: %@ • Fade de saída: %@",
        "ro": "Preset: %@ • Format: %@ • Fade in: %@ • Fade out: %@",
        "ru": "Пресет: %@ • Формат: %@ • Плавное появление: %@ • Плавное затухание: %@",
        "sk": "Predvoľba: %@ • Formát: %@ • Nábeh: %@ • Doznievanie: %@",
        "sv": "Förval: %@ • Format: %@ • Fade in: %@ • Fade out: %@",
        "th": "ค่าที่ตั้งไว้: %@ • รูปแบบ: %@ • เฟดเข้า: %@ • เฟดออก: %@",
        "tr": "Ön ayar: %@ • Format: %@ • Giriş fade: %@ • Çıkış fade: %@",
        "uk": "Пресет: %@ • Формат: %@ • Плавний вхід: %@ • Плавний вихід: %@",
        "vi": "Mẫu sẵn: %@ • Định dạng: %@ • Fade vào: %@ • Fade ra: %@",
        "zh-Hans": "预设：%@ • 格式：%@ • 淡入：%@ • 淡出：%@",
        "zh-Hant": "預設：%@ • 格式：%@ • 淡入：%@ • 淡出：%@"
    ]

    private static let helpResultMessageOverrides: [String: String] = [
        "ar": "التحويل جاهز • شارك الصوت • احفظ في «الملفات»",
        "bg": "Конвертирането е готово • Сподели аудио • Запази във «Файлове»",
        "ca": "Conversió llesta • Comparteix l'àudio • Desa a «Fitxers»",
        "cs": "Převod je hotový • Sdílet audio • Uložit do «Souborů»",
        "da": "Konvertering klar • Del lyd • Gem i «Filer»",
        "de": "Konvertierung fertig • Audio teilen • In «Dateien» speichern",
        "el": "Η μετατροπή ολοκληρώθηκε • Κοινή χρήση ήχου • Αποθήκευση στα «Αρχεία»",
        "en": "Conversion ready • Share audio • Save to «Files»",
        "es": "Conversión lista • Compartir audio • Guardar en «Archivos»",
        "fi": "Muunnos valmis • Jaa ääni • Tallenna «Tiedostoihin»",
        "fr": "Conversion prête • Partager l'audio • Enregistrer dans «Fichiers»",
        "he": "ההמרה מוכנה • שתף שמע • שמור ב«קבצים»",
        "hi": "रूपांतरण तैयार • ऑडियो साझा करें • «फ़ाइलें» में सहेजें",
        "hr": "Pretvorba je gotova • Podijeli audio • Spremi u «Datoteke»",
        "hu": "Konvertálás kész • Hang megosztása • Mentés a «Fájlok»-ba",
        "id": "Konversi siap • Bagikan audio • Simpan ke «File»",
        "it": "Conversione pronta • Condividi audio • Salva in «File»",
        "ja": "変換完了 • 音声を共有 • «ファイル»に保存",
        "ko": "변환 완료 • 오디오 공유 • «파일»에 저장",
        "ms": "Penukaran siap • Kongsi audio • Simpan ke «Fail»",
        "nb": "Konvertering klar • Del lyd • Lagre i «Filer»",
        "nl": "Conversie klaar • Audio delen • Opslaan in «Bestanden»",
        "no": "Konvertering klar • Del lyd • Lagre i «Filer»",
        "pl": "Konwersja gotowa • Udostępnij audio • Zapisz w «Plikach»",
        "pt": "Conversão pronta • Compartilhar áudio • Salvar em «Arquivos»",
        "ro": "Conversie gata • Distribuie audio • Salvează în «Fișiere»",
        "ru": "Конвертация готова • Поделиться аудио • Сохранить в «Файлы»",
        "sk": "Konverzia je hotová • Zdieľať audio • Uložiť do «Súborov»",
        "sv": "Konvertering klar • Dela ljud • Spara i «Filer»",
        "th": "แปลงเสร็จแล้ว • แชร์เสียง • บันทึกไปที่ «ไฟล์»",
        "tr": "Dönüştürme hazır • Sesi paylaş • «Dosyalar»a kaydet",
        "uk": "Конвертацію завершено • Поділитися аудіо • Зберегти у «Файли»",
        "vi": "Chuyển đổi xong • Chia sẻ âm thanh • Lưu vào «Tệp»",
        "zh-Hans": "转换完成 • 分享音频 • 保存到 «文件»",
        "zh-Hant": "轉換完成 • 分享音訊 • 儲存到 «檔案»"
    ]
}
