import SwiftUI
import AVKit
import UniformTypeIdentifiers
import Speech

struct VideoFile: Identifiable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
}

struct SubtitleEntry: Identifiable {
    let id = UUID()
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

class AppViewModel: ObservableObject {
    @Published var videoFiles: [VideoFile] = []
    @Published var selectedVideo: VideoFile?
    @Published var subtitles: [SubtitleEntry] = []
    @Published var selectedSubtitle: URL?
    @Published var subtitleText: String = ""
    @Published var player: AVPlayer?
    @Published var currentTime: TimeInterval = 0
    @Published var isPlaying = false
    @Published var playbackSpeed: Float = 1.0
    @Published var currentSubtitleIndex: Int?
    
    // Speech recognition
    @Published var isListening = false
    @Published var recognizedText = ""
    @Published var speechRecognitionPermission = false
    
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var timeObserver: Any?
    
    init() {
        setupSpeechRecognizer()
        setupPlayerObserver()
    }
    
    deinit {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
    }
    
    func loadVideos(from directory: URL) {
        let exts = ["mp4", "avi", "mov", "mkv", "webm", "mp3"]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        self.videoFiles = files.filter { exts.contains($0.pathExtension.lowercased()) }.map { VideoFile(url: $0) }
    }
    
    func selectVideo(_ video: VideoFile) {
        selectedVideo = video
        player = AVPlayer(url: video.url)
        loadSubtitles(for: video)
        setupPlayerObserver()
    }
    
    func loadSubtitles(for video: VideoFile) {
        let base = video.url.deletingPathExtension().lastPathComponent
        let dir = video.url.deletingLastPathComponent()
        let vtt = dir.appendingPathComponent("\(base).vtt")
        if FileManager.default.fileExists(atPath: vtt.path) {
            self.selectedSubtitle = vtt
            self.subtitleText = (try? String(contentsOf: vtt)) ?? ""
            self.subtitles = parseVTT(vtt)
        } else {
            self.selectedSubtitle = nil
            self.subtitleText = ""
            self.subtitles = []
        }
    }
    
    func parseVTT(_ url: URL) -> [SubtitleEntry] {
        guard let content = try? String(contentsOf: url) else { return [] }
        var entries: [SubtitleEntry] = []
        let lines = content.components(separatedBy: .newlines)
        var currentStart: TimeInterval?
        var currentEnd: TimeInterval?
        var currentText = ""
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("-->") {
                let parts = trimmed.components(separatedBy: " --> ")
                if parts.count == 2 {
                    currentStart = timeToSeconds(parts[0])
                    currentEnd = timeToSeconds(parts[1])
                }
            } else if !trimmed.isEmpty,
                      let start = currentStart,
                      let end = currentEnd,
                      !trimmed.allSatisfy({ $0.isNumber }) { // Skip timestamp numbers
                currentText += trimmed + " "
            } else if trimmed.isEmpty,
                      let start = currentStart,
                      let end = currentEnd,
                      !currentText.isEmpty {
                entries.append(SubtitleEntry(
                    start: start,
                    end: end,
                    text: currentText.trimmingCharacters(in: .whitespaces)
                ))
                currentStart = nil
                currentEnd = nil
                currentText = ""
            }
        }
        return entries
    }
    
    func timeToSeconds(_ time: String) -> TimeInterval? {
        let parts = time.split(separator: ":")
        guard parts.count == 3 else { return nil }
        let h = Double(parts[0]) ?? 0
        let m = Double(parts[1]) ?? 0
        let s = Double(parts[2].replacingOccurrences(of: ",", with: ".")) ?? 0
        return h * 3600 + m * 60 + s
    }
    
    func setupPlayerObserver() {
        guard let player = player else { return }
        
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
        }
        
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            self?.currentTime = time.seconds
            self?.updateCurrentSubtitle()
        }
        
        // Observe player state
        player.addObserver(self, forKeyPath: "timeControlStatus", options: [.new], context: nil)
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "timeControlStatus", let player = object as? AVPlayer {
            DispatchQueue.main.async {
                self.isPlaying = player.timeControlStatus == .playing
            }
        }
    }
    
    func updateCurrentSubtitle() {
        currentSubtitleIndex = subtitles.firstIndex { subtitle in
            currentTime >= subtitle.start && currentTime <= subtitle.end
        }
    }
    
    func seekToSubtitle(_ subtitle: SubtitleEntry) {
        player?.seek(to: CMTime(seconds: subtitle.start, preferredTimescale: 600))
    }
    
    func togglePlayPause() {
        guard let player = player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }
    
    func setPlaybackSpeed(_ speed: Float) {
        playbackSpeed = speed
        player?.rate = speed
    }
    
    func rewindSeconds(_ seconds: TimeInterval) {
        guard let player = player else { return }
        let newTime = max(0, player.currentTime().seconds - seconds)
        player.seek(to: CMTime(seconds: newTime, preferredTimescale: 600))
    }
    
    func forwardSeconds(_ seconds: TimeInterval) {
        guard let player = player else { return }
        let newTime = player.currentTime().seconds + seconds
        player.seek(to: CMTime(seconds: newTime, preferredTimescale: 600))
    }
    
    // MARK: - Speech Recognition
    
    func setupSpeechRecognizer() {
        speechRecognizer = SFSpeechRecognizer()
        
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            DispatchQueue.main.async {
                self?.speechRecognitionPermission = authStatus == .authorized
            }
        }
    }
    
    func startSpeechRecognition() {
        guard speechRecognitionPermission else { return }
        
        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }
        
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("Audio session setup failed: \(error)")
            return
        }
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }
        
        recognitionRequest.shouldReportPartialResults = true
        
        let inputNode = audioEngine.inputNode
        
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            DispatchQueue.main.async {
                if let result = result {
                    self?.recognizedText = result.bestTranscription.formattedString
                }
                
                if error != nil || result?.isFinal == true {
                    self?.audioEngine.stop()
                    inputNode.removeTap(onBus: 0)
                    self?.recognitionRequest = nil
                    self?.recognitionTask = nil
                    self?.isListening = false
                }
            }
        }
        
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            self.recognitionRequest?.append(buffer)
        }
        
        audioEngine.prepare()
        do {
            try audioEngine.start()
            isListening = true
        } catch {
            print("Audio engine start failed: \(error)")
        }
    }
    
    func stopSpeechRecognition() {
        audioEngine.stop()
        recognitionRequest?.endAudio()
        isListening = false
    }
    
    func saveSubtitles() {
        guard let url = selectedSubtitle else { return }
        try? subtitleText.write(to: url, atomically: true, encoding: .utf8)
        subtitles = parseVTT(url)
    }
}

struct ContentView: View {
    @StateObject var vm = AppViewModel()
    @State private var showFileImporter = false
    @State private var showSubtitleEditor = false
    
    var body: some View {
        NavigationView {
            // Sidebar
            VStack {
                List(selection: $vm.selectedVideo) {
                    ForEach(vm.videoFiles) { video in
                        HStack {
                            Image(systemName: video.url.pathExtension.lowercased() == "mp3" ? "music.note" : "video")
                                .foregroundColor(.secondary)
                            Text(video.name)
                                .lineLimit(2)
                        }
                        .onTapGesture {
                            vm.selectVideo(video)
                        }
                    }
                }
                .listStyle(SidebarListStyle())
                
                Button("Open Folder") {
                    showFileImporter = true
                }
                .padding()
            }
            .frame(minWidth: 250)
            
            // Main content
            VStack {
                if let player = vm.player {
                    // Video player
                    VideoPlayer(player: player)
                        .frame(height: 300)
                        .cornerRadius(8)
                    
                    // Player controls
                    HStack {
                        Button(action: { vm.rewindSeconds(10) }) {
                            Image(systemName: "gobackward.10")
                        }
                        
                        Button(action: vm.togglePlayPause) {
                            Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        }
                        
                        Button(action: { vm.forwardSeconds(10) }) {
                            Image(systemName: "goforward.10")
                        }
                        
                        Spacer()
                        
                        Text("Speed:")
                        Picker("Speed", selection: $vm.playbackSpeed) {
                            Text("0.5x").tag(Float(0.5))
                            Text("0.75x").tag(Float(0.75))
                            Text("1x").tag(Float(1.0))
                            Text("1.25x").tag(Float(1.25))
                            Text("1.5x").tag(Float(1.5))
                            Text("2x").tag(Float(2.0))
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(width: 200)
                        .onChange(of: vm.playbackSpeed) { speed in
                            vm.setPlaybackSpeed(speed)
                        }
                    }
                    .padding()
                    
                    // Current subtitle display
                    if let currentIndex = vm.currentSubtitleIndex,
                       currentIndex < vm.subtitles.count {
                        Text(vm.subtitles[currentIndex].text)
                            .font(.title2)
                            .padding()
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(8)
                            .padding(.horizontal)
                    }
                    
                    // Subtitle list
                    if !vm.subtitles.isEmpty {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 8) {
                                    ForEach(Array(vm.subtitles.enumerated()), id: \.element.id) { index, subtitle in
                                        SubtitleRow(
                                            subtitle: subtitle,
                                            isActive: vm.currentSubtitleIndex == index,
                                            onTap: { vm.seekToSubtitle(subtitle) }
                                        )
                                        .id(subtitle.id)
                                    }
                                }
                                .padding()
                            }
                            .onChange(of: vm.currentSubtitleIndex) { index in
                                if let index = index, index < vm.subtitles.count {
                                    withAnimation {
                                        proxy.scrollTo(vm.subtitles[index].id, anchor: .center)
                                    }
                                }
                            }
                        }
                    }
                    
                    // Speech recognition controls
                    if vm.speechRecognitionPermission {
                        VStack {
                            HStack {
                                Button(vm.isListening ? "Stop Listening" : "Start Listening") {
                                    if vm.isListening {
                                        vm.stopSpeechRecognition()
                                    } else {
                                        vm.startSpeechRecognition()
                                    }
                                }
                                .foregroundColor(vm.isListening ? .red : .blue)
                                
                                if vm.isListening {
                                    Image(systemName: "mic.fill")
                                        .foregroundColor(.red)
                                        .scaleEffect(1.2)
                                }
                            }
                            
                            if !vm.recognizedText.isEmpty {
                                Text("You said: \(vm.recognizedText)")
                                    .padding()
                                    .background(Color.blue.opacity(0.1))
                                    .cornerRadius(8)
                            }
                        }
                        .padding()
                    }
                    
                    // Subtitle editor button
                    if vm.selectedSubtitle != nil {
                        Button("Edit Subtitles") {
                            showSubtitleEditor = true
                        }
                        .padding()
                    }
                }
            }
            .padding()
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                vm.loadVideos(from: url)
            }
        }
        .sheet(isPresented: $showSubtitleEditor) {
            SubtitleEditorView(vm: vm, isPresented: $showSubtitleEditor)
        }
    }
}

struct SubtitleRow: View {
    let subtitle: SubtitleEntry
    let isActive: Bool
    let onTap: () -> Void
    
    var body: some View {
        HStack {
            Button(action: onTap) {
                HStack {
                    Image(systemName: "play.fill")
                        .font(.caption)
                    Text(formatTime(subtitle.start))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(PlainButtonStyle())
            
            Text(subtitle.text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isActive ? Color.blue.opacity(0.2) : Color.clear)
        .cornerRadius(8)
        .onTapGesture(perform: onTap)
    }
    
    func formatTime(_ sec: TimeInterval) -> String {
        let h = Int(sec) / 3600
        let m = (Int(sec) % 3600) / 60
        let s = Int(sec) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

struct SubtitleEditorView: View {
    @ObservedObject var vm: AppViewModel
    @Binding var isPresented: Bool
    
    var body: some View {
        VStack {
            HStack {
                Text("Subtitle Editor")
                    .font(.title)
                Spacer()
                Button("Done") {
                    isPresented = false
                }
            }
            .padding()
            
            TextEditor(text: $vm.subtitleText)
                .font(.system(.body, design: .monospaced))
                .padding()
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .padding()
            
            HStack {
                Button("Save") {
                    vm.saveSubtitles()
                    isPresented = false
                }
                .keyboardShortcut(.return, modifiers: .command)
                
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 600, height: 500)
    }
}

@main
struct ShadowingGabatteApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
