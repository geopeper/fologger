//
//  ContentView.swift
//  fologger
//
//  Created by 蘇昱齊 on 2025/12/13.
//

import SwiftUI
import CoreLocation
import Combine

// MARK: - 1. 資料模型 (Models)

enum ObservationType: String, CaseIterable, Codable, Identifiable {
    case light = "亮度"
    case tree = "路樹"
    case microclimate = "微氣候"
    case sidewalk = "人行道"
    case custom = "自定義"
    
    var id: String { self.rawValue }
    
    var icon: String {
        switch self {
        case .light: return "sun.max.fill"
        case .tree: return "leaf.fill"
        case .microclimate: return "thermometer.sun.fill"
        case .sidewalk: return "figure.walk.circle.fill"
        case .custom: return "pencil.circle.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .light: return .orange
        case .tree: return .green
        case .microclimate: return .teal
        case .sidewalk: return .indigo
        case .custom: return .gray
        }
    }
}

struct FieldRecord: Identifiable, Codable {
    let id = UUID()
    var index: Int
    let timestamp: Date
    
    let latitude: Double
    let longitude: Double
    let hAccuracy: Double
    
    let type: ObservationType
    let mainValue: Double?
    let mainNote: String?
    
    var csvLine: String {
        let tStr = ISO8601DateFormatter().string(from: timestamp)
        let valStr = mainValue != nil ? String(format: "%.2f", mainValue!) : ""
        let noteStr = (mainNote ?? "").replacingOccurrences(of: ",", with: "，")
        
        return "\(index),\(tStr),\(latitude),\(longitude),\(hAccuracy),\(type.rawValue),\(valStr),\(noteStr)"
    }
}

// MARK: - 2. 核心控制器 (Controller)

class FieldLoggerController: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    
    @Published var location: CLLocation?
    @Published var authStatus: CLAuthorizationStatus = .notDetermined
    @Published var records: [FieldRecord] = []
    @Published var lastError: String?
    
    var isCategoryLocked: Bool {
        return !records.isEmpty
    }
    
    var lockedType: ObservationType? {
        return records.first?.type
    }
    
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
    }
    
    func startLocation() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            manager.startUpdatingLocation()
        }
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        self.authStatus = manager.authorizationStatus
        if authStatus == .authorizedWhenInUse || authStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        DispatchQueue.main.async { self.location = loc }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async { self.lastError = error.localizedDescription }
    }
    
    // --- 資料操作 ---
    
    func addRecord(type: ObservationType, value: Double?, note: String?) {
        guard let loc = location else { return }
        
        if let locked = lockedType, locked != type {
            return
        }
        
        let newRecord = FieldRecord(
            index: records.count + 1,
            timestamp: Date(),
            latitude: loc.coordinate.latitude,
            longitude: loc.coordinate.longitude,
            hAccuracy: loc.horizontalAccuracy,
            type: type,
            mainValue: value,
            mainNote: note
        )
        records.append(newRecord)
    }
    
    func deleteRecord(at offsets: IndexSet) {
        records.remove(atOffsets: offsets)
        for (i, _) in records.enumerated() {
            records[i].index = i + 1
        }
    }
    
    func clearRecords() {
        records.removeAll()
    }
    
    func generateCSV() -> URL? {
        let header = "index,timestamp,lat,lon,h_acc,type,value,note\n"
        let content = records.map { $0.csvLine }.joined(separator: "\n")
        let finalString = header + content
        
        let filename = "GeoLog_\(Int(Date().timeIntervalSince1970)).csv"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        
        do {
            try finalString.write(to: path, atomically: true, encoding: .utf8)
            return path
        } catch {
            return nil
        }
    }
    
    func generateGeoJSON() -> URL? {
        var features: [[String: Any]] = []
        
        for r in records {
            let props: [String: Any] = [
                "index": r.index,
                "type": r.type.rawValue,
                "value": r.mainValue ?? 0,
                "note": r.mainNote ?? "",
                "timestamp": ISO8601DateFormatter().string(from: r.timestamp)
            ]
            
            let feature: [String: Any] = [
                "type": "Feature",
                "properties": props,
                "geometry": [
                    "type": "Point",
                    "coordinates": [r.longitude, r.latitude]
                ]
            ]
            features.append(feature)
        }
        
        let featureCollection = ["type": "FeatureCollection", "features": features] as [String : Any]
        
        let filename = "GeoLog_\(Int(Date().timeIntervalSince1970)).geojson"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        
        do {
            let data = try JSONSerialization.data(withJSONObject: featureCollection, options: .prettyPrinted)
            try data.write(to: path)
            return path
        } catch {
            return nil
        }
    }
}

// MARK: - 4. 視圖 (View)

struct ContentView: View {
    @StateObject private var controller = FieldLoggerController()
    
    @State private var selectedMode: ObservationType = .light
    @State private var inputValue: String = ""
    @State private var inputNote: String = ""
    @State private var isSharePresented = false
    @State private var shareURL: URL?
    
    @State private var currentTime = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    // 🟢 新增：自定義時間格式器 (MM/dd HH:mm)
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter
    }()
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 20) {
                        // 1. 資訊面板
                        infoDashboard
                        
                        // 2. 圓形類別選擇器
                        observationTypePicker
                        
                        // 3. 輸入卡片
                        inputCard
                        
                        // 4. 匯出按鈕
                        actionArea
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                
                Section(header: Text("最近紀錄").font(.headline)) {
                    if controller.records.isEmpty {
                        Text("尚無資料")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(controller.records.reversed()) { r in
                            recordRow(r)
                        }
                        .onDelete { indexSet in
                            let originalCount = controller.records.count
                            let originalIndices = indexSet.map { originalCount - 1 - $0 }
                            controller.deleteRecord(at: IndexSet(originalIndices))
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Geo Field Logger")
            .scrollDismissesKeyboard(.interactively)
            .onAppear { controller.startLocation() }
            .onReceive(timer) { input in currentTime = input }
            .sheet(isPresented: $isSharePresented) {
                if let url = shareURL {
                    ShareSheet(activityItems: [url])
                }
            }
            .onChange(of: controller.records.count) { count in
                if count == 1 {
                    if let type = controller.lockedType {
                        selectedMode = type
                    }
                }
            }
        }
    }
    
    // --- UI Components ---
    
    private var infoDashboard: some View {
        VStack(spacing: 12) {
            
            // 時間卡片
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("時間")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    
                    // 🟢 修改：使用自定義的 dateFormatter
                    Text(currentTime, formatter: dateFormatter)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.bold)
                }
                
                Spacer()
            }
            .padding()
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .cornerRadius(12)
            
            // GPS 卡片
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("GPS 位置")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    
                    if let loc = controller.location {
                        Text("\(loc.coordinate.latitude, specifier: "%.6f"), \(loc.coordinate.longitude, specifier: "%.6f")")
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(.bold)
                    } else {
                        Text("定位中...")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                // 精度顯示
                if let loc = controller.location {
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 4) {
                            Text("精度")
                                .font(.caption2)
                            Image(systemName: loc.horizontalAccuracy <= 10 ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        }
                        .foregroundStyle(loc.horizontalAccuracy <= 10 ? .green : .orange)
                        
                        Text("±\(loc.horizontalAccuracy, specifier: "%.0f")m")
                            .font(.caption.bold())
                            .foregroundStyle(loc.horizontalAccuracy <= 10 ? .green : .orange)
                    }
                }
            }
            .padding()
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .cornerRadius(12)
        }
        .padding(.top, 10)
    }
    
    private var observationTypePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                ForEach(ObservationType.allCases) { type in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                            if !controller.isCategoryLocked {
                                selectedMode = type
                                inputValue = ""
                                inputNote = ""
                            }
                        }
                    } label: {
                        VStack(spacing: 8) {
                            ZStack {
                                Circle()
                                    .fill(
                                        selectedMode == type ? type.color :
                                            (controller.isCategoryLocked ? Color.gray.opacity(0.1) : Color(uiColor: .secondarySystemGroupedBackground))
                                    )
                                    .frame(width: 56, height: 56)
                                    .shadow(color: .black.opacity(selectedMode == type ? 0.2 : 0.05), radius: 4, x: 0, y: 2)
                                
                                Image(systemName: type.icon)
                                    .font(.title2)
                                    .foregroundStyle(
                                        selectedMode == type ? .white :
                                            (controller.isCategoryLocked ? .gray : type.color)
                                    )
                            }
                            
                            Text(type.rawValue)
                                .font(.caption)
                                .fontWeight(selectedMode == type ? .bold : .regular)
                                .foregroundStyle(
                                    selectedMode == type ? .primary :
                                        (controller.isCategoryLocked ? .secondary : .primary)
                                )
                        }
                    }
                    .disabled(controller.isCategoryLocked && selectedMode != type)
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
    
    private var isInputValid: Bool {
        if controller.location == nil { return false }
        let valueEmpty = inputValue.trimmingCharacters(in: .whitespaces).isEmpty
        let noteEmpty = inputNote.trimmingCharacters(in: .whitespaces).isEmpty
        return !(valueEmpty && noteEmpty)
    }
    
    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(selectedMode.rawValue)
                    .font(.title3.bold())
                
                Spacer()
                
                if controller.isCategoryLocked {
                    Label("鎖定中", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(.thinMaterial)
                        .cornerRadius(8)
                }
            }
            
            Group {
                switch selectedMode {
                case .light:
                    inputRow(title: "光度 (Lux)", placeholder: "例如 350", isNumber: true)
                case .tree:
                    inputRow(title: "胸徑 (cm)", placeholder: "例如 15.5", isNumber: true)
                    noteRow(title: "樹種/特徵", placeholder: "例如 樟樹, 根系隆起")
                case .microclimate:
                    inputRow(title: "溫度 (°C)", placeholder: "例如 28.5", isNumber: true)
                    noteRow(title: "環境描述", placeholder: "例如 半遮蔭, 柏油鋪面")
                case .sidewalk:
                    inputRow(title: "淨寬 (cm)", placeholder: "例如 90", isNumber: true)
                    noteRow(title: "障礙物類型", placeholder: "例如 變電箱, 違停")
                case .custom:
                    noteRow(title: "類別/標籤", placeholder: "自定義類別")
                    inputRow(title: "數值 (選填)", placeholder: "如有數值可填", isNumber: true)
                }
            }
            
            Button {
                saveData()
            } label: {
                HStack {
                    Spacer()
                    Image(systemName: "plus")
                    Text("記錄點位")
                    Spacer()
                }
                .font(.headline)
                .padding()
                .background(isInputValid ? selectedMode.color : Color.gray.opacity(0.3))
                .foregroundStyle(isInputValid ? .white : .gray)
                .cornerRadius(12)
            }
            .disabled(!isInputValid)
            .animation(.easeInOut, value: isInputValid)
            .buttonStyle(.borderless)
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
    }
    
    private func inputRow(title: String, placeholder: String, isNumber: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            TextField(placeholder, text: $inputValue)
                .keyboardType(isNumber ? .decimalPad : .default)
                .padding(12)
                .background(Color(uiColor: .systemBackground))
                .cornerRadius(8)
        }
    }
    
    private func noteRow(title: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            TextField(placeholder, text: $inputNote)
                .padding(12)
                .background(Color(uiColor: .systemBackground))
                .cornerRadius(8)
        }
    }
    
    private var actionArea: some View {
        HStack {
            Text("已記錄: \(controller.records.count) 筆")
                .font(.headline)
                .monospacedDigit()
            
            Spacer()
            
            Menu {
                Button(action: {
                    shareURL = controller.generateCSV()
                    isSharePresented = true
                }) {
                    Label("匯出 CSV", systemImage: "doc.text")
                }
                
                Button(action: {
                    shareURL = controller.generateGeoJSON()
                    isSharePresented = true
                }) {
                    Label("匯出 GeoJSON", systemImage: "globe")
                }
                
                Divider()
                
                Button(role: .destructive, action: {
                    controller.clearRecords()
                    inputValue = ""
                    inputNote = ""
                }) {
                    Label("清空並解鎖類別", systemImage: "trash")
                }
            } label: {
                Image(systemName: "square.and.arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.blue)
            }
            .disabled(controller.records.isEmpty)
            .buttonStyle(.borderless)
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    private func recordRow(_ r: FieldRecord) -> some View {
        HStack {
            Text("#\(r.index)")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            
            Image(systemName: r.type.icon)
                .foregroundStyle(r.type.color)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(r.type.rawValue)
                        .font(.caption.bold())
                    
                    // 🟢 修改：列表的時間也同步套用 MM/dd HH:mm 格式
                    Text(r.timestamp, formatter: dateFormatter)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                if let val = r.mainValue {
                    Text("\(val, specifier: "%.1f")")
                        .font(.body.monospacedDigit())
                }
            }
            
            Spacer()
            
            Text(r.mainNote ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
    
    // --- Actions ---
    
    private func saveData() {
        guard isInputValid else { return }
        
        let val = Double(inputValue)
        let note = inputNote.isEmpty ? nil : inputNote
        
        controller.addRecord(type: selectedMode, value: val, note: note)
        
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        
        inputValue = ""
        inputNote = ""
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    var activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    ContentView()
}
