import QtQuick
import Qt5Compat.GraphicalEffects
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Mpris
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    property string navidromeUrl: pluginData.navidromeUrl ?? ""
    property string navidromeUser: pluginData.navidromeUser ?? ""
    property string navidromePassword: pluginData.navidromePassword ?? ""
    property bool cachingEnabled: pluginData.cachingEnabled ?? true
    property string playerWhitelist: pluginData.playerWhitelist ?? ""

    readonly property MprisPlayer activePlayer: MprisController.activePlayer
    property var allPlayers: MprisController.availablePlayers

    // -------------------------------------------------------------------------
    // Enum namespaces
    // -------------------------------------------------------------------------

    QtObject {
        id: status
        readonly property int none: 0
        readonly property int searching: 1
        readonly property int found: 2
        readonly property int notFound: 3
        readonly property int error: 4
        readonly property int skippedConfig: 5
        readonly property int skippedFound: 6
        readonly property int skippedPlain: 7
        readonly property int cacheHit: 11
        readonly property int cacheMiss: 12
        readonly property int cacheDisabled: 13
    }

    QtObject {
        id: lyricState
        readonly property int idle: 0
        readonly property int loading: 1
        readonly property int synced: 2
        readonly property int notFound: 3
    }

    QtObject {
        id: lyricSrc
        readonly property int none: 0
        readonly property int navidrome: 1
        readonly property int lrclib: 2
        readonly property int cache: 3
        readonly property int musixmatch: 4
        readonly property int lrcapi: 5
    }

    // -------------------------------------------------------------------------
    // Lyrics state
    // -------------------------------------------------------------------------

    property var lyricsLines: []
    property int currentLineIndex: -1
    property bool lyricsLoading: lyricStatus === lyricState.loading
    property string _lastFetchedTrack: ""
    property string _lastFetchedArtist: ""
    property var _cancelActiveFetch: null
    
    property var _fallbackLines: []
    property int _fallbackSource: lyricSrc.none

    property int navidromeStatus: status.none
    property int lrclibStatus: status.none
    property int lrcapiStatus: status.none
    property int musixmatchStatus: status.none
    property int cacheStatus: status.none

    property int lyricStatus: lyricState.idle
    property int lyricSource: lyricSrc.none

    property string currentTitle: activePlayer?.trackTitle ?? ""
    property string currentArtist: activePlayer?.trackArtist ?? ""
    property string currentAlbum: activePlayer?.trackAlbum ?? ""
    property real currentDuration: activePlayer?.length ?? 0

    property string currentLyricText: {
        if (lyricsLoading) return "Searching lyrics…";
        if (lyricsLines.length > 0 && currentLineIndex >= 0) return lyricsLines[currentLineIndex].text || "♪ ♪ ♪";
        if (currentTitle) return currentTitle;
        return "No lyrics";
    }

    property bool _configValid: navidromeUrl !== "" && navidromeUser !== "" && navidromePassword !== ""

    on_ConfigValidChanged: {
        console.info("[MusicLyrics] Navidrome configured: " + (_configValid ? "yes (" + navidromeUrl + ")" : "no"));
        if (activePlayer && currentTitle) fetchDebounceTimer.restart();
    }

    Timer {
        id: fetchDebounceTimer
        interval: 300
        onTriggered: root.fetchLyricsIfNeeded()
    }
    onCurrentTitleChanged: fetchDebounceTimer.restart()
    onCurrentArtistChanged: fetchDebounceTimer.restart()

    property bool _forceUpdate: false

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _resetLyricsState() {
        lyricsLines = [];
        currentLineIndex = -1;
        _fallbackLines = [];
        _fallbackSource = lyricSrc.none;
        navidromeStatus = status.none;
        lrclibStatus = status.none;
        lrcapiStatus = status.none;
        musixmatchStatus = status.none;
        cacheStatus = status.none;
        lyricStatus = lyricState.loading;
        lyricSource = lyricSrc.none;
    }

    function _setMusixmatchNotFound(musixmatchStatusVal) {
        musixmatchStatus = musixmatchStatusVal;
        _fetchFromLrcApi(_lastFetchedTrack, _lastFetchedArtist);
    }

    function _setFinalNotFound(lrclibStatusVal) {
        if (root._fallbackLines.length > 0) {
            root.lyricsLines = root._fallbackLines;
            root.lyricStatus = lyricState.synced;
            root.lyricSource = root._fallbackSource;
            if (root._fallbackSource === lyricSrc.navidrome) {
                root.navidromeStatus = status.found; 
                root.lrclibStatus = lrclibStatusVal;
            } else if (root._fallbackSource === lyricSrc.lrclib) {
                root.lrclibStatus = status.found;
            }
            console.info("[MusicLyrics] Using unsynced fallback lyrics (" + root._fallbackLines.length + " lines)");
        } else {
            lrclibStatus = lrclibStatusVal;
            lyricStatus = lyricState.notFound;
        }
        root._cancelActiveFetch = null;
    }

    // -------------------------------------------------------------------------
    // Cache helpers
    // -------------------------------------------------------------------------

    function _fnv1a32(str) {
        var hash = 0x811c9dc5;
        for (var i = 0; i < str.length; i++) {
            hash = ((hash ^ str.charCodeAt(i)) * 0x01000193) >>> 0;
        }
        return ("00000000" + hash.toString(16)).slice(-8);
    }

    function _cacheKey(title, artist) {
        return _fnv1a32((title + "\x00" + artist).toLowerCase());
    }

    readonly property string _cacheDir: (Quickshell.env("HOME") || "") + "/.cache/musicLyrics"

    function _cacheFilePath(title, artist) {
        return _cacheDir + "/" + _cacheKey(title, artist) + ".json";
    }

    Timer {
        id: xhrTimeoutTimer
        repeat: false
        property var onTimeout: null
        onTriggered: if (onTimeout) onTimeout()
    }

    Timer {
        id: xhrRetryTimer
        repeat: false
        property var onRetry: null
        onTriggered: if (onRetry) onRetry()
    }

    property bool _cacheDirReady: false

    Process {
        id: mkdirProcess
        command: ["mkdir", "-p", root._cacheDir]
        running: false
    }

    function _ensureCacheDir() {
        if (_cacheDirReady) return;
        _cacheDirReady = true;
        mkdirProcess.running = true;
    }

    Component {
        id: cacheReaderComponent
        FileView {
            property var callback
            blockLoading: true
            preload: true
            onLoaded: {
                try { callback(JSON.parse(text())); } catch (e) { callback(null); }
                destroy();
            }
            onLoadFailed: {
                callback(null);
                destroy();
            }
        }
    }

    function readFromCache(title, artist, callback) {
        cacheReaderComponent.createObject(root, {
            path: _cacheFilePath(title, artist),
            callback: callback
        });
    }

    Component {
        id: cacheWriterComponent
        FileView {
            property string cTitle
            property string cArtist
            blockWrites: false
            atomicWrites: true
            onSaved: {
                console.info("[MusicLyrics] Cache: written for \"" + cTitle + "\" by " + cArtist + " (" + path + ")");
                destroy();
            }
            onSaveFailed: {
                console.warn("[MusicLyrics] Cache: failed to write for \"" + cTitle + "\"");
                destroy();
            }
        }
    }

    function writeToCache(title, artist, lines, source) {
        _ensureCacheDir();
        var writer = cacheWriterComponent.createObject(root, {
            path: _cacheFilePath(title, artist),
            cTitle: title,
            cArtist: artist
        });
        writer.setText(JSON.stringify({ lines: lines, source: source }));
    }

    // -------------------------------------------------------------------------
    // Fetch orchestration
    // -------------------------------------------------------------------------

    function fetchLyricsIfNeeded() {
        var player = root.activePlayer;
        var whitelist = root.playerWhitelist.split(",").map(function(s) { return s.trim(); });
        if (!player) return;
        var identity = player.identity || "";
        var isMusicPlayer = false;
        for (var i = 0; i < whitelist.length; i++) {
            if (identity.toLowerCase().includes(whitelist[i])) {
                isMusicPlayer = true;
                break;
            }
        }
        if (!isMusicPlayer) {
            _resetLyricsState();
            return;
        }

        if (!currentTitle) return;
        if (currentTitle === _lastFetchedTrack && currentArtist === _lastFetchedArtist) return;

        if (_cancelActiveFetch) {
            _cancelActiveFetch();
            _cancelActiveFetch = null;
        }

        _lastFetchedTrack = currentTitle;
        _lastFetchedArtist = currentArtist;
        _resetLyricsState();

        var durationStr = currentDuration > 0 ? (Math.floor(currentDuration / 60) + ":" + ("0" + Math.floor(currentDuration % 60)).slice(-2)) : "unknown";
        console.info("[MusicLyrics] ▶ Track changed: \"" + currentTitle + "\" by " + currentArtist + (currentAlbum ? " [" + currentAlbum + "]" : "") + " (" + durationStr + ")");

        var capturedTitle = currentTitle;
        var capturedArtist = currentArtist;

        function _startFetch() {
            if (_configValid) {
                _fetchFromNavidrome(capturedTitle, capturedArtist);
            } else {
                navidromeStatus = status.skippedConfig;
                _fetchFromMusixmatch(capturedTitle, capturedArtist);
            }
        }

        if (cachingEnabled) {
            readFromCache(capturedTitle, capturedArtist, function (cached) {
                if (capturedTitle !== root._lastFetchedTrack || capturedArtist !== root._lastFetchedArtist) return;
                if (cached && cached.lines && cached.lines.length > 0) {
                    root.lyricsLines = cached.lines;
                    root.lyricStatus = lyricState.synced;
                    root.lyricSource = cached.source > 0 ? cached.source : lyricSrc.cache;
                    root.cacheStatus = status.cacheHit;
                    root.navidromeStatus = status.skippedFound;
                    root.lrclibStatus = status.skippedFound;
                    root.lrcapiStatus = status.skippedFound;
                    root.musixmatchStatus = status.skippedFound;
                    console.info("[MusicLyrics] ✓ Cache: lyrics loaded for \"" + capturedTitle + "\" (" + cached.lines.length + " lines)");
                    return;
                }
                root.cacheStatus = status.cacheMiss;
                _startFetch();
            });
        } else {
            cacheStatus = status.cacheDisabled;
            _startFetch();
        }
    }

    // -------------------------------------------------------------------------
    // XMLHttpRequest helper
    // -------------------------------------------------------------------------

    function _xhrGet(url, timeoutMs, onSuccess, onError, customHeaders) {
        var retriesLeft = 2;
        var retryDelay = 3000;
        var attempt = 0;
        var cancelled = false;
        var currentXhr = null;

        function _attempt() {
            attempt++;
            currentXhr = new XMLHttpRequest();
            var done = false;

            xhrTimeoutTimer.stop();
            xhrTimeoutTimer.interval = timeoutMs;
            xhrTimeoutTimer.onTimeout = function () {
                if (!done && !cancelled) {
                    done = true;
                    currentXhr.abort();
                    _retry("timeout");
                }
            };
            xhrTimeoutTimer.start();

            currentXhr.onreadystatechange = function () {
                if (currentXhr.readyState !== XMLHttpRequest.DONE || done || cancelled) return;
                done = true;
                xhrTimeoutTimer.stop();
                if (currentXhr.status === 0) {
                    _retry("network error (status 0)");
                    return;
                }
                var responseBody = (currentXhr.responseText || "").trim();
                if (responseBody.length === 0) {
                    _retry("empty response (HTTP " + currentXhr.status + ")");
                    return;
                }
                onSuccess(currentXhr.responseText, currentXhr.status);
            };
            currentXhr.open("GET", url);
            if (customHeaders) {
                for (var key in customHeaders) currentXhr.setRequestHeader(key, customHeaders[key]);
            } else {
                currentXhr.setRequestHeader("User-Agent", "DankMaterialShell MusicLyrics/1.5.0 (https://github.com/Gasiyu/dms-plugin-musiclyrics)");
                currentXhr.setRequestHeader("Accept", "application/json");
            }
            currentXhr.send();
        }

        function _retry(errMsg) {
            if (cancelled) return;
            if (retriesLeft > 0) {
                retriesLeft--;
                console.warn("[MusicLyrics] _xhrGet: " + errMsg + " — retrying (attempt " + (attempt + 1) + ", " + retriesLeft + " left): " + url);
                xhrRetryTimer.stop();
                xhrRetryTimer.interval = retryDelay;
                xhrRetryTimer.onRetry = _attempt;
                xhrRetryTimer.start();
            } else {
                onError(errMsg);
            }
        }

        _attempt();

        return function cancel() {
            cancelled = true;
            xhrTimeoutTimer.stop();
            xhrRetryTimer.stop();
            if (currentXhr) currentXhr.abort();
            console.info("[MusicLyrics] ⊘ XHR cancelled: " + url);
        };
    }

    // -------------------------------------------------------------------------
    // Navidrome fetch
    // -------------------------------------------------------------------------

    function _navidromeUrl(endpoint, extraParams) {
        var base = navidromeUrl.replace(/\/+$/, "") + "/rest/" + endpoint;
        var auth = "u=" + encodeURIComponent(navidromeUser) + "&p=" + encodeURIComponent(navidromePassword) + "&v=1.16.1&c=DankMaterialShell&f=json";
        return base + "?" + (extraParams ? extraParams + "&" : "") + auth;
    }

    function _fetchFromNavidrome(expectedTitle, expectedArtist) {
        navidromeStatus = status.searching;
        var searchUrl = _navidromeUrl("search3", "query=" + encodeURIComponent(expectedTitle) + "&songCount=5&albumCount=0&artistCount=0");
        root._cancelActiveFetch = _xhrGet(searchUrl, 15000, function (responseText, httpStatus) {
            var rawData = (responseText || "").trim();
            if (rawData.length === 0) {
                root.navidromeStatus = status.error;
                root._fetchFromMusixmatch(expectedTitle, expectedArtist);
                return;
            }
            try {
                var result = JSON.parse(rawData);
                var songs = result["subsonic-response"]?.searchResult3?.song;
                if (!songs || songs.length === 0) {
                    root.navidromeStatus = status.notFound;
                    root._fetchFromMusixmatch(expectedTitle, expectedArtist);
                    return;
                }

                var songId = songs[0].id;
                for (var i = 0; i < songs.length; i++) {
                    if (songs[i].title.toLowerCase() === expectedTitle.toLowerCase()) {
                        songId = songs[i].id;
                        break;
                    }
                }

                root._fetchNavidromeLyrics(songId, expectedTitle, expectedArtist);
            } catch (e) {
                root.navidromeStatus = status.error;
                root._fetchFromMusixmatch(expectedTitle, expectedArtist);
            }
        }, function (errMsg) {
            root.navidromeStatus = status.error;
            root._fetchFromMusixmatch(expectedTitle, expectedArtist);
        });
    }

    function _fetchNavidromeLyrics(songId, expectedTitle, expectedArtist) {
        var lyricsUrl = _navidromeUrl("getLyricsBySongId", "id=" + encodeURIComponent(songId));
        root._cancelActiveFetch = _xhrGet(lyricsUrl, 15000, function (responseText, httpStatus) {
            var rawData = (responseText || "").trim();
            if (rawData.length === 0) {
                root.navidromeStatus = status.error;
                root._fetchFromMusixmatch(expectedTitle, expectedArtist);
                return;
            }
            try {
                var result = JSON.parse(rawData);
                var lyricsList = result["subsonic-response"]?.lyricsList?.structuredLyrics;
                if (!lyricsList || lyricsList.length === 0) {
                    root.navidromeStatus = status.notFound;
                    root._fetchFromMusixmatch(expectedTitle, expectedArtist);
                    return;
                }

                var synced = null;
                var unsynced = null;
                for (var i = 0; i < lyricsList.length; i++) {
                    if (lyricsList[i].synced) {
                        synced = lyricsList[i];
                        break;
                    } else {
                        unsynced = lyricsList[i];
                    }
                }

                if (synced && synced.line) {
                    var lines = synced.line.map(function (l) {
                        return { time: (l.start || 0) / 1000, text: l.value || "" };
                    });
                    root.lyricsLines = lines;
                    root.navidromeStatus = status.found;
                    root.lyricStatus = lyricState.synced;
                    root.lyricSource = lyricSrc.navidrome;
                    root.lrclibStatus = status.skippedFound;
                    root.lrcapiStatus = status.skippedFound;
                    root.musixmatchStatus = status.skippedFound;
                    root._cancelActiveFetch = null;
                    if (root.cachingEnabled) root.writeToCache(expectedTitle, expectedArtist, lines, lyricSrc.navidrome);
                } else if (unsynced && unsynced.line) {
                    root._fallbackLines = unsynced.line.map(function (l) {
                        return { time: -1, text: l.value || "" };
                    });
                    root._fallbackSource = lyricSrc.navidrome;
                    root.navidromeStatus = status.skippedPlain;
                    root._fetchFromMusixmatch(expectedTitle, expectedArtist);
                } else {
                    root.navidromeStatus = status.notFound;
                    root._fetchFromMusixmatch(expectedTitle, expectedArtist);
                }
            } catch (e) {
                root.navidromeStatus = status.error;
                root._fetchFromMusixmatch(expectedTitle, expectedArtist);
            }
        }, function (errMsg) {
            root.navidromeStatus = status.error;
            root._fetchFromMusixmatch(expectedTitle, expectedArtist);
        });
    }

    // -------------------------------------------------------------------------
    // lrclib.net fetch
    // -------------------------------------------------------------------------

    function _fetchFromLrclib(expectedTitle, expectedArtist) {
        if (lyricStatus === lyricState.synced) {
            lrclibStatus = status.skippedFound;
            return;
        }

        lrclibStatus = status.searching;
        var url = "https://lrclib.net/api/get?artist_name=" + encodeURIComponent(expectedArtist) + "&track_name=" + encodeURIComponent(expectedTitle);
        if (currentAlbum) url += "&album_name=" + encodeURIComponent(currentAlbum);
        if (currentDuration > 0) url += "&duration=" + Math.round(currentDuration);

        root._cancelActiveFetch = _xhrGet(url, 20000, function (responseText, httpStatus) {
            var rawData = (responseText || "").trim();
            if (rawData.length === 0) {
                root._setFinalNotFound(status.error);
                return;
            }
            try {
                var result = JSON.parse(rawData);
                if (result.statusCode === 404 || result.error) {
                    root._setFinalNotFound(status.notFound);
                } else if (result.syncedLyrics) {
                    root.lyricsLines = root.parseLrc(result.syncedLyrics);
                    root.lrclibStatus = status.found;
                    root.lyricStatus = lyricState.synced;
                    root.lyricSource = lyricSrc.lrclib;
                    root._cancelActiveFetch = null;
                    if (root.cachingEnabled) root.writeToCache(expectedTitle, expectedArtist, root.lyricsLines, lyricSrc.lrclib);
                } else if (result.plainLyrics) {
                    root._fallbackLines = result.plainLyrics.split("\n").map(function(l) { return { time: -1, text: l.trim() }; }).filter(function(l) { return l.text.length > 0; });
                    root._fallbackSource = lyricSrc.lrclib;
                    root._setFinalNotFound(status.skippedPlain);
                } else {
                    root._setFinalNotFound(status.notFound);
                }
            } catch (e) {
                root._setFinalNotFound(status.error);
            }
        }, function (errMsg) {
            root._setFinalNotFound(status.error);
        });
    }

    // -------------------------------------------------------------------------
    // api.lrc.cx fetch
    // -------------------------------------------------------------------------

    function _fetchFromLrcApi(expectedTitle, expectedArtist) {
        if (lyricStatus === lyricState.synced) {
            lrcapiStatus = status.skippedFound;
            return;
        }

        lrcapiStatus = status.searching;
        var url = "https://api.lrc.cx/lyrics?artist=" + encodeURIComponent(expectedArtist) + "&title=" + encodeURIComponent(expectedTitle);
        if (currentAlbum) url += "&album=" + encodeURIComponent(currentAlbum);

        root._cancelActiveFetch = _xhrGet(url, 20000, function (responseText, httpStatus) {
            var rawData = (responseText || "").trim();
            if (rawData.length === 0) {
                lrcapiStatus = status.error;
                return;
            }
            try {
                var lines = parseLrc(rawData);
                if (lines && lines.length > 0) {
                    root.lyricsLines = lines;
                    root.lyricStatus = lyricState.synced;
                    root.lrcapiStatus = status.found;
                    root.lyricSource = lyricSrc.lrcapi;
                    root._cancelActiveFetch = null;
                    if (root.cachingEnabled) root.writeToCache(expectedTitle, expectedArtist, root.lyricsLines, lyricSrc.lrcapi);
                } else {
                    lrcapiStatus = status.notFound;
                }
                _fetchFromLrclib(_lastFetchedTrack, _lastFetchedArtist);
            } catch (e) {
                root._setFinalNotFound(status.error);
            }
        }, function (errMsg) {
            root._setFinalNotFound(status.error);
        });
    }

    // -------------------------------------------------------------------------
    // Musixmatch fetch
    // -------------------------------------------------------------------------

    property string _musixmatchToken: pluginData.musixmatchToken ?? ""

    function _musixmatchHeaders() {
        return {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36",
            "Accept": "application/json",
            "Accept-Language": "en-US,en;q=0.9",
            "Origin": "https://www.musixmatch.com",
            "Referer": "https://www.musixmatch.com/"
        };
    }

    function _fetchMusixmatchToken(callback) {
        if (_musixmatchToken) {
            callback(_musixmatchToken);
            return;
        }

        var url = "https://apic-desktop.musixmatch.com/ws/1.1/token.get" + "?user_language=en" + "&app_id=web-desktop-app-v1.0" + "&t=" + Date.now();
        root._cancelActiveFetch = _xhrGet(url, 15000, function (responseText, httpStatus) {
            try {
                var result = JSON.parse(responseText);
                var body = result.message ? result.message.body : undefined;
                var token = body ? body.user_token : undefined;
                if (token && token !== "undefined" && token !== "") {
                    root._musixmatchToken = token;
                    pluginService.savePluginData("musicLyrics", "musixmatchToken", token);
                    callback(token);
                } else {
                    callback(null);
                }
            } catch (e) {
                callback(null);
            }
        }, function (errMsg) {
            callback(null);
        }, _musixmatchHeaders());
    }

    function _fetchFromMusixmatch(expectedTitle, expectedArtist, _tokenRetried) {
        if (lyricStatus === lyricState.synced) {
            musixmatchStatus = status.skippedFound;
            return;
        }

        musixmatchStatus = status.searching;
        _fetchMusixmatchToken(function (token) {
            if (!token) {
                root._setMusixmatchNotFound(status.error);
                return;
            }

            if (expectedTitle !== root._lastFetchedTrack || expectedArtist !== root._lastFetchedArtist) return;

            var trackUrl = "https://apic-desktop.musixmatch.com/ws/1.1/matcher.track.get" + "?q_track=" + encodeURIComponent(expectedTitle) + "&q_artist=" + encodeURIComponent(expectedArtist) + "&page_size=1&page=1" + "&app_id=web-desktop-app-v1.0" + "&usertoken=" + encodeURIComponent(token) + "&t=" + Date.now();

            root._cancelActiveFetch = root._xhrGet(trackUrl, 15000, function (responseText, httpStatus) {
                try {
                    var result = JSON.parse(responseText);
                    var headerStatusCode = result.message && result.message.header ? result.message.header.status_code : 0;
                    if (headerStatusCode === 401 || headerStatusCode === 402) {
                        if (!_tokenRetried) {
                            root._musixmatchToken = "";
                            root._fetchFromMusixmatch(expectedTitle, expectedArtist, true);
                        } else {
                            root._setMusixmatchNotFound(status.error);
                        }
                        return;
                    }
                    var track = result.message.body.track;
                    var trackId = track.track_id;
                    if (!trackId) {
                        root._setMusixmatchNotFound(status.notFound);
                        return;
                    }

                    var hasSubtitles = track.has_subtitles === 1;
                    if (!hasSubtitles) {
                        root._setMusixmatchNotFound(status.notFound);
                        return;
                    }

                    root._fetchMusixmatchLyrics(trackId, token, expectedTitle, expectedArtist);
                } catch (e) {
                    root._setMusixmatchNotFound(status.error);
                }
            }, function (errMsg) {
                root._setMusixmatchNotFound(status.error);
            }, _musixmatchHeaders());
        });
    }

    function _fetchMusixmatchLyrics(trackId, token, expectedTitle, expectedArtist, _tokenRetried) {
        var url = "https://apic-desktop.musixmatch.com/ws/1.1/track.subtitle.get" + "?track_id=" + trackId + "&subtitle_format=lrc" + "&app_id=web-desktop-app-v1.0" + "&usertoken=" + encodeURIComponent(token) + "&t=" + Date.now();

        root._cancelActiveFetch = _xhrGet(url, 15000, function (responseText, httpStatus) {
            if (expectedTitle !== root._lastFetchedTrack || expectedArtist !== root._lastFetchedArtist) return;

            try {
                var result = JSON.parse(responseText);
                var headerStatusCode = result.message && result.message.header ? result.message.header.status_code : 0;
                if (headerStatusCode === 401 || headerStatusCode === 402) {
                    if (!_tokenRetried) {
                        root._musixmatchToken = "";
                        root._fetchFromMusixmatch(expectedTitle, expectedArtist, true);
                    } else {
                        root._setMusixmatchNotFound(status.error);
                    }
                    return;
                }
                var subtitleBody = result.message.body.subtitle.subtitle_body;
                if (!subtitleBody || subtitleBody.trim() === "") {
                    root._setMusixmatchNotFound(status.notFound);
                    return;
                }

                var lines = root.parseLrc(subtitleBody);
                if (lines.length === 0) {
                    root._setMusixmatchNotFound(status.notFound);
                    return;
                }

                root.lyricsLines = lines;
                root.musixmatchStatus = status.found;
                root.lrclibStatus = status.skippedFound;
                root.lrcapiStatus = status.skippedFound;
                root.lyricStatus = lyricState.synced;
                root.lyricSource = lyricSrc.musixmatch;
                root._cancelActiveFetch = null;
                if (root.cachingEnabled) root.writeToCache(expectedTitle, expectedArtist, lines, lyricSrc.musixmatch);
            } catch (e) {
                root._setMusixmatchNotFound(status.error);
            }
        }, function (errMsg) {
            root._setMusixmatchNotFound(status.error);
        }, _musixmatchHeaders());
    }

    // -------------------------------------------------------------------------
    // LRC parser (with word-sync tag stripping)
    // -------------------------------------------------------------------------

    function parseLrc(lrcText) {
        var timeRegex = /\[(\d{2}):(\d{2})\.(\d{2,3})\]/;
        var wordTimeRegex = /<\d{2}:\d{2}\.\d{2,3}>/g;
        
        var result = lrcText.split("\n").reduce(function (acc, rawLine) {
            var line = rawLine.trim();
            if (!line) return acc;
            var match = timeRegex.exec(line);
            if (!match) return acc;
            var millis = parseInt(match[3]);
            if (match[3].length === 2) millis *= 10;
            acc.push({
                time: parseInt(match[1]) * 60 + parseInt(match[2]) + millis / 1000,
                text: line.replace(/\[\d{2}:\d{2}\.\d{2,3}\]/g, "").replace(wordTimeRegex, "").trim()
            });
            return acc;
        }, []);
        result.sort(function (a, b) {
            return a.time - b.time;
        });
        return result;
    }

    // -------------------------------------------------------------------------
    // Position tracking for synced/unsynced lyrics
    // -------------------------------------------------------------------------

    Timer {
        id: positionTimer
        interval: 50 
        running: activePlayer && lyricsLines.length > 0
        repeat: true
        
        onTriggered: {
            if (!activePlayer) return;
            var pos = activePlayer.position || 0;
            var newIndex = -1;
            
            if (lyricsLines.length > 0 && (lyricsLines[0].time === undefined || lyricsLines[0].time < 0)) {
                var lineDur = currentDuration > 0 ? currentDuration / lyricsLines.length : 4;
                newIndex = Math.floor(pos / lineDur);
                if (newIndex >= lyricsLines.length) newIndex = lyricsLines.length - 1;
                if (newIndex < 0) newIndex = 0;
            } else {
                for (var i = lyricsLines.length - 1; i >= 0; i--) {
                    if (pos >= lyricsLines[i].time) {
                        newIndex = i;
                        break;
                    }
                }
            }
            if (newIndex !== currentLineIndex) {
                currentLineIndex = newIndex;
            }
            root._forceUpdate = !root._forceUpdate;
        }
    }

    // -------------------------------------------------------------------------
    // Status chip helpers
    // -------------------------------------------------------------------------

    function isSourceActive(s) {
        return s === status.found || s === status.cacheHit || s === status.skippedFound;
    }

    readonly property var _chipMeta: ({
            [status.searching]: { color: Theme.secondary, icon: "hourglass_top", label: "Searching…" },
            [status.found]: { color: Theme.primary, icon: "check_circle", label: "Found" },
            [status.notFound]: { color: Theme.warning, icon: "cancel", label: "Not found" },
            [status.error]: { color: Theme.error, icon: "error", label: "Error" },
            [status.skippedConfig]: { color: Theme.warning, icon: "block", label: "Skipped — Not configured" },
            [status.skippedFound]: { color: Theme.warning, icon: "block", label: "Skipped — Already found" },
            [status.skippedPlain]: { color: Theme.warning, icon: "block", label: "Skipped — Plain lyrics only" },
            [status.cacheHit]: { color: Theme.primary, icon: "check_circle", label: "Hit — Loaded from cache" },
            [status.cacheMiss]: { color: Theme.warning, icon: "cancel", label: "Miss — Not in cache" },
            [status.cacheDisabled]: { color: Theme.surfaceVariantText, icon: "do_not_disturb_on", label: "Disabled" }
        })

    function _chip(val) {
        return _chipMeta[val] ?? { color: Theme.surfaceContainerHighest, icon: "radio_button_unchecked", label: "Idle" };
    }

    // -------------------------------------------------------------------------
    // Bar Pill
    // -------------------------------------------------------------------------

    horizontalBarPill: root.activePlayer ? hPillComponent : null

    Component {
        id: hPillComponent
        RowLayout {
            spacing: Theme.spacingS

            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                width: chipContent.implicitWidth + Theme.spacingS * 2
                height: Theme.fontSizeSmall + Theme.spacingXS
                radius: 12
                color: Theme.primary

                Row {
                    id: chipContent
                    anchors.centerIn: parent
                    spacing: Theme.spacingXS

                    DankIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: activePlayer && activePlayer.playbackState === MprisPlaybackState.Playing ? "lyrics" : "pause"
                        size: Theme.fontSizeSmall
                        color: Theme.background
                    }

                    StyledText {
                        text: root.lyricSource === lyricSrc.navidrome ? "Navidrome" : root.lyricSource === lyricSrc.lrclib ? "lrclib" : root.lyricSource === lyricSrc.musixmatch ? "Musixmatch" : ""
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.background
                        anchors.verticalCenter: parent.verticalCenter
                        maximumLineCount: 1
                        elide: Text.ElideRight
                        visible: root.lyricsLines.length > 0
                    }
                }
            }

            StyledText {
                text: root.currentLyricText
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
                Layout.alignment: Qt.AlignVCenter
                Layout.maximumWidth: 400 // Sane fallback, allows parent layout to restrict it further if needed
                maximumLineCount: 1
                elide: Text.ElideRight
            }
        }
    }

    verticalBarPill: root.activePlayer ? vPillComponent : null

    Component {
        id: vPillComponent
        Column {
            spacing: Theme.spacingXS

            DankIcon {
                name: "lyrics"
                size: Theme.iconSize
                color: root.lyricsLines.length > 0 ? Theme.primary : Theme.surfaceVariantText
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: "♪"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    // -------------------------------------------------------------------------
    // Popout: Now Playing + Lyrics Stream View
    // -------------------------------------------------------------------------

    function _formatDuration(seconds) {
        if (seconds <= 0) return "—";
        var m = Math.floor(seconds / 60);
        var s = Math.floor(seconds % 60);
        return m + ":" + ("0" + s).slice(-2);
    }

    popoutContent: Component {
        PopoutComponent {
            headerText: "Music Lyrics"

            Item {
                width: parent.width
                implicitHeight: popoutLayout.implicitHeight

                Column {
                    id: popoutLayout
                    width: parent.width
                    spacing: Theme.spacingM

                    // ── Now Playing Card ──
                    Rectangle {
                        id: nowPlayingCard
                        width: parent.width
                        height: nowPlayingContent.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: root.activePlayer ? Theme.withAlpha(Theme.primary, 0.08) : Theme.withAlpha(Theme.surfaceContainerHighest, 0.5)

                        Row {
                            id: nowPlayingContent
                            anchors {
                                left: parent.left
                                right: parent.right
                                top: parent.top
                                margins: Theme.spacingM
                            }
                            spacing: Theme.spacingM

                            Column {
                                width: _coverArt.visible ? parent.width - _coverArt.width - parent.spacing : parent.width
                                spacing: Theme.spacingS

                                Row {
                                    spacing: Theme.spacingS
                                    width: parent.width

                                    DankIcon {
                                        name: root.activePlayer && root.activePlayer.playbackState === MprisPlaybackState.Playing ? "play_circle" : "pause_circle"
                                        size: 20
                                        color: root.activePlayer ? Theme.primary : Theme.surfaceVariantText
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                    StyledText {
                                        text: root.activePlayer ? "Now Playing - " + (root.activePlayer.identity || "Unknown Player") : "No Active Player"
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.DemiBold
                                        color: root.activePlayer ? Theme.primary : Theme.surfaceVariantText
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }

                                StyledText {
                                    width: parent.width
                                    text: root.currentTitle || "—"
                                    font.pixelSize: Theme.fontSizeLarge + 2
                                    font.weight: Font.Bold
                                    color: Theme.surfaceText
                                    maximumLineCount: 2
                                    elide: Text.ElideRight
                                    wrapMode: Text.WordWrap
                                    visible: root.activePlayer
                                }

                                Column {
                                    width: parent.width
                                    spacing: 2
                                    visible: root.activePlayer

                                    Row {
                                        spacing: Theme.spacingXS
                                        DankIcon { name: "person"; size: 14; color: Theme.surfaceVariantText; anchors.verticalCenter: parent.verticalCenter }
                                        StyledText {
                                            text: root.currentArtist || "Unknown Artist"
                                            font.pixelSize: Theme.fontSizeMedium
                                            color: Theme.surfaceText
                                            anchors.verticalCenter: parent.verticalCenter
                                            maximumLineCount: 1
                                            elide: Text.ElideRight
                                        }
                                    }

                                    Row {
                                        spacing: Theme.spacingXS
                                        visible: root.currentAlbum !== ""
                                        DankIcon { name: "album"; size: 14; color: Theme.surfaceVariantText; anchors.verticalCenter: parent.verticalCenter }
                                        StyledText {
                                            text: root.currentAlbum
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                            anchors.verticalCenter: parent.verticalCenter
                                            maximumLineCount: 1
                                            elide: Text.ElideRight
                                        }
                                    }
                                }

                                Column {
                                    width: parent.width
                                    spacing: 4
                                    visible: root.activePlayer && root.currentDuration > 0

                                    DankSeekbar {
                                        id: progressSeekbar
                                        width: parent.width
                                        height: 20
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        activePlayer: root.activePlayer
                                    }

                                    Timer {
                                        interval: 50
                                        running: root.activePlayer !== null
                                        repeat: true
                                        onTriggered: {
                                            if (progressSeekbar && root.activePlayer) {
                                                try {
                                                    var pos = root.activePlayer.position || 0;
                                                    var len = Math.max(1, root.activePlayer.length || 1);
                                                    progressSeekbar.value = Math.min(1, pos / len);
                                                } catch (e) {}
                                            }
                                            root._forceUpdate = !root._forceUpdate;
                                        }
                                    }

                                    Row {
                                        width: parent.width

                                        StyledText {
                                            id: _currentTime
                                            text: {
                                                void root._forceUpdate;
                                                if (!activePlayer) return "0:00";
                                                const rawPos = Math.max(0, activePlayer.position || 0);
                                                const pos = activePlayer.length ? rawPos % Math.max(1, activePlayer.length) : rawPos;
                                                const minutes = Math.floor(pos / 60);
                                                const seconds = Math.floor(pos % 60);
                                                return minutes + ":" + (seconds < 10 ? "0" : "") + seconds;
                                            }
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            color: Theme.surfaceVariantText
                                        }

                                        Item { width: parent.width - _currentTime.implicitWidth - _endTime.implicitWidth; height: 1 }

                                        StyledText {
                                            id: _endTime
                                            text: {
                                                if (!activePlayer || !activePlayer.length) return "0:00";
                                                const dur = Math.max(0, activePlayer.length || 0);
                                                return Math.floor(dur / 60) + ":" + (Math.floor(dur % 60) < 10 ? "0" : "") + Math.floor(dur % 60);
                                            }
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            color: Theme.surfaceVariantText
                                        }
                                    }
                                }
                            }

                            DankAlbumArt {
                                id: _coverArt
                                width: 80
                                height: 80
                                visible: root.activePlayer && (root.activePlayer.trackArtUrl ?? "") !== ""
                                anchors.verticalCenter: parent.verticalCenter
                                activePlayer: root.activePlayer
                                showAnimation: true
                            }
                        }
                    }

                    // ── Lyrics Stream View ──
                    ListView {
                        id: lyricsView
                        width: parent.width
                        height: 300 
                        clip: true
                        model: root.lyricsLines
                        spacing: Theme.spacingS
                        
                        currentIndex: root.currentLineIndex
                        
                        preferredHighlightBegin: height * 0.4
                        preferredHighlightEnd: height * 0.6
                        highlightRangeMode: ListView.ApplyRange
                        highlightMoveDuration: 400
                        highlightResizeDuration: 400
                        highlightFollowsCurrentItem: true
                        
                        Text {
                            anchors.centerIn: parent
                            visible: root.lyricsLines.length === 0
                            text: root.lyricsLoading ? "Searching lyrics…" : "No lyrics found"
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeMedium
                        }
                        
                        delegate: Item {
                            id: lineDelegate
                            width: ListView.view.width
                            height: Math.max(lyricTextDim.implicitHeight, lyricTextBright.implicitHeight) + Theme.spacingS
                            
                            property bool isActive: ListView.isCurrentItem
                            property bool isMusicSymbol: /^[\s♪♫♬♩♭♯*]+$/.test(modelData.text || "")
                            
                            property real progress: {
                                void root._forceUpdate;
                                if (!isActive) return 0;
                                
                                var currTime = root.activePlayer ? root.activePlayer.position : 0;
                                if (modelData.time === undefined || modelData.time < 0 || isMusicSymbol) {
                                    return 1.0; // Display whole sentence/symbol at once
                                } else {
                                    var nextTime = (index + 1 < root.lyricsLines.length) ? root.lyricsLines[index+1].time : currTime + 5;
                                    var dur = nextTime - modelData.time;
                                    return Math.max(0, Math.min(1, (currTime - modelData.time) / Math.max(0.1, dur)));
                                }
                            }
                            
                            // Dim background text layer
                            StyledText {
                                id: lyricTextDim
                                width: parent.width
                                text: modelData.text || " "
                                font.pixelSize: Theme.fontSizeLarge
                                font.weight: Font.Normal 
                                color: Theme.surfaceText
                                opacity: lineDelegate.isActive ? 0.4 : 0.35
                                wrapMode: Text.WordWrap
                                horizontalAlignment: Text.AlignHCenter
                            }
                            
                            // Bright foreground text layer, wiped by OpacityMask
                            StyledText {
                                id: lyricTextBright
                                width: parent.width
                                text: modelData.text || " "
                                font.pixelSize: Theme.fontSizeLarge
                                font.weight: Font.Normal 
                                color: Theme.surfaceText
                                opacity: 1.0
                                wrapMode: Text.WordWrap
                                horizontalAlignment: Text.AlignHCenter
                                visible: lineDelegate.isActive && lineDelegate.progress > 0.01
                                
                                layer.enabled: true
                                layer.effect: OpacityMask {
                                    // Creates a mask that matches the text wrapping perfectly
                                    maskSource: Column {
                                        width: lyricTextBright.width
                                        height: lyricTextBright.height
                                        
                                        Repeater {
                                            model: lyricTextBright.lineCount > 0 ? lyricTextBright.lineCount : 1
                                            
                                            Item {
                                                id: lineMask
                                                width: parent.width
                                                height: lyricTextBright.lineCount > 0 ? (lyricTextBright.height / lyricTextBright.lineCount) : parent.height
                                                
                                                readonly property real lineFraction: lyricTextBright.lineCount > 0 ? (1.0 / lyricTextBright.lineCount) : 1.0
                                                readonly property real localProgress: (lineDelegate.progress - index * lineFraction) / lineFraction
                                                readonly property real p: Math.max(0.0, Math.min(1.0, localProgress))
                                                
                                                Rectangle {
                                                    anchors.fill: parent
                                                    color: lineMask.p >= 1.0 ? "#FF000000" : "#00000000"
                                                }
                                                
                                                LinearGradient {
                                                    anchors.fill: parent
                                                    visible: lineMask.p > 0.0 && lineMask.p < 1.0
                                                    start: Qt.point(0, 0)
                                                    end: Qt.point(parent.width, 0)
                                                    gradient: Gradient {
                                                        GradientStop { position: 0.0; color: "#FF000000" }
                                                        GradientStop { position: Math.max(0.0, lineMask.p - 0.05); color: "#FF000000" }
                                                        GradientStop { position: Math.min(1.0, lineMask.p + 0.05); color: "#00000000" }
                                                        GradientStop { position: 1.0; color: "#00000000" }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ── Bottom Source Indicators ──
                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: Theme.spacingM

                        Rectangle {
                            width: 32; height: 32; radius: 16
                            color: Theme.withAlpha(root.isSourceActive(root.cacheStatus) ? Theme.primary : Theme.surfaceContainerHighest, 0.2)
                            DankIcon { anchors.centerIn: parent; name: "cached"; size: 16; color: root.isSourceActive(root.cacheStatus) ? Theme.primary : Theme.surfaceVariantText }
                        }
                        Rectangle {
                            width: 32; height: 32; radius: 16
                            color: Theme.withAlpha(root.isSourceActive(root.navidromeStatus) ? Theme.primary : Theme.surfaceContainerHighest, 0.2)
                            DankIcon { anchors.centerIn: parent; name: "cloud"; size: 16; color: root.isSourceActive(root.navidromeStatus) ? Theme.primary : Theme.surfaceVariantText }
                        }
                        Rectangle {
                            width: 32; height: 32; radius: 16
                            color: Theme.withAlpha(root.isSourceActive(root.musixmatchStatus) ? Theme.primary : Theme.surfaceContainerHighest, 0.2)
                            DankIcon { anchors.centerIn: parent; name: "music_note"; size: 16; color: root.isSourceActive(root.musixmatchStatus) ? Theme.primary : Theme.surfaceVariantText }
                        }
                        Rectangle {
                            width: 32; height: 32; radius: 16
                            color: Theme.withAlpha(root.isSourceActive(root.lrcapiStatus) ? Theme.primary : Theme.surfaceContainerHighest, 0.2)
                            DankIcon { anchors.centerIn: parent; name: "genres"; size: 16; color: root.isSourceActive(root.lrcapiStatus) ? Theme.primary : Theme.surfaceVariantText }
                        }
                        Rectangle {
                            width: 32; height: 32; radius: 16
                            color: Theme.withAlpha(root.isSourceActive(root.lrclibStatus) ? Theme.primary : Theme.surfaceContainerHighest, 0.2)
                            DankIcon { anchors.centerIn: parent; name: "library_music"; size: 16; color: root.isSourceActive(root.lrclibStatus) ? Theme.primary : Theme.surfaceVariantText }
                        }
                    }
                }
            }
        }
    }

    popoutWidth: 380
    popoutHeight: 520

    Component.onCompleted: {
        console.info("[MusicLyrics] Plugin loaded");
    }
}
