import Foundation
import CoreLocation
import CoreMotion
import CoreBluetooth
import UserNotifications
import CoreData

class TrackingManager: NSObject, ObservableObject {
    @Published var isTracking = false
    @Published var currentMiles: Double = 0.0
    @Published var isMotionDetectionEnabled = UserDefaults.standard.bool(forKey: "motionDetectionEnabled")
    @Published var isBluetoothDetectionEnabled = UserDefaults.standard.bool(forKey: "bluetoothDetectionEnabled")
    
    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionActivityManager()
    private var centralManager: CBCentralManager?
    private var startLocation: CLLocation?
    private var lastLocation: CLLocation?
    private var totalDistance: Double = 0.0
    private var tripStartTime: Date?
    private var stationaryTimer: Timer?
    private var stationaryStartTime: Date?
    private let stationaryThreshold: TimeInterval = 300 // 5 minutes
    private var trackedVehicleUUID: UUID?
    private var currentTripId: UUID?
    private var connectedPeripherals: [UUID: CBPeripheral] = [:]
    
    let persistenceController = PersistenceController.shared
    
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        
        if isBluetoothDetectionEnabled {
            centralManager = CBCentralManager(delegate: self, queue: nil)
        }
    }
    
    func setup() {
        requestLocationPermission()
        requestNotificationPermission()
        
        if isMotionDetectionEnabled {
            startMotionDetection()
        }
        
        if isBluetoothDetectionEnabled {
            startBluetoothDetection()
        }
    }
    
    private func requestLocationPermission() {
        locationManager.requestAlwaysAuthorization()
    }
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted {
                self.registerNotificationCategories()
            }
        }
    }
    
    private func registerNotificationCategories() {
        let businessAction = UNNotificationAction(identifier: "BUSINESS_ACTION", title: "Business", options: [])
        let medicalAction = UNNotificationAction(identifier: "MEDICAL_ACTION", title: "Medical", options: [])
        let charityAction = UNNotificationAction(identifier: "CHARITY_ACTION", title: "Charity", options: [])
        
        let category = UNNotificationCategory(
            identifier: "TRIP_COMPLETE",
            actions: [businessAction, medicalAction, charityAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
    
    func startMotionDetection() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        
        motionManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self = self, let activity = activity else { return }
            
            if activity.automotive && !self.isTracking {
                self.startTracking()
            } else if !activity.automotive && self.isTracking && self.isMotionDetectionEnabled {
                self.checkStationary()
            }
        }
    }
    
    func stopMotionDetection() {
        motionManager.stopActivityUpdates()
    }
    
    func startBluetoothDetection() {
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil)
        }
    }
    
    func stopBluetoothDetection() {
        centralManager = nil
    }
    
    private func startTracking() {
        guard !isTracking else { return }
        
        isTracking = true
        tripStartTime = Date()
        currentTripId = UUID()
        startLocation = nil
        lastLocation = nil
        totalDistance = 0.0
        currentMiles = 0.0
        
        locationManager.startUpdatingLocation()
        stationaryTimer?.invalidate()
        stationaryStartTime = nil
    }
    
    private func stopTracking() {
        guard isTracking else { return }
        
        isTracking = false
        locationManager.stopUpdatingLocation()
        stationaryTimer?.invalidate()
        stationaryStartTime = nil
        
        saveTrip()
    }
    
    private func checkStationary() {
        if stationaryStartTime == nil {
            stationaryStartTime = Date()
        }
        
        if let startTime = stationaryStartTime,
           Date().timeIntervalSince(startTime) >= stationaryThreshold {
            stopTracking()
        }
    }
    
    private func saveTrip() {
        guard let tripId = currentTripId,
              totalDistance > 0 else { return }
        
        let context = persistenceController.container.viewContext
        let trip = Trip(context: context)
        trip.id = tripId
        trip.date = tripStartTime ?? Date()
        trip.startOdometer = 0.0 // Will be calculated from GPS
        trip.endOdometer = totalDistance / 1609.34 // Convert meters to miles
        trip.category = TripCategory.business.rawValue // Default, user can change via notification
        trip.purpose = nil
        trip.notes = "Auto-tracked trip"
        
        // Find vehicle if Bluetooth UUID matches
        if let vehicleUUID = trackedVehicleUUID {
            let request = NSFetchRequest<Vehicle>(entityName: "Vehicle")
            request.predicate = NSPredicate(format: "bluetoothUUID == %@", vehicleUUID.uuidString)
            if let vehicle = try? context.fetch(request).first {
                trip.vehicle = vehicle
            }
        }
        
        do {
            try context.save()
            sendTripCompleteNotification(tripId: tripId, miles: trip.miles)
        } catch {
            print("Error saving auto-tracked trip: \(error.localizedDescription)")
            // Trip will be lost, but at least we log the error
        }
    }
    
    private func sendTripCompleteNotification(tripId: UUID, miles: Double) {
        let content = UNMutableNotificationContent()
        content.title = "Trip Complete"
        content.body = String(format: "Tracked %.1f miles. Classify trip category?", miles)
        content.sound = .default
        content.categoryIdentifier = "TRIP_COMPLETE"
        content.userInfo = ["tripId": tripId.uuidString]
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    
    var isMotionDetectionEnabledBinding: Binding<Bool> {
        Binding(
            get: { self.isMotionDetectionEnabled },
            set: { newValue in
                self.isMotionDetectionEnabled = newValue
                UserDefaults.standard.set(newValue, forKey: "motionDetectionEnabled")
                if newValue {
                    self.startMotionDetection()
                } else {
                    self.stopMotionDetection()
                }
            }
        )
    }
    
    var isBluetoothDetectionEnabledBinding: Binding<Bool> {
        Binding(
            get: { self.isBluetoothDetectionEnabled },
            set: { newValue in
                self.isBluetoothDetectionEnabled = newValue
                UserDefaults.standard.set(newValue, forKey: "bluetoothDetectionEnabled")
                if newValue {
                    self.startBluetoothDetection()
                } else {
                    self.stopBluetoothDetection()
                }
            }
        )
    }
}

extension TrackingManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy > 0 else { return }
        
        if startLocation == nil {
            startLocation = location
            lastLocation = location
            return
        }
        
        if let last = lastLocation {
            let distance = location.distance(from: last)
            totalDistance += distance
            currentMiles = totalDistance / 1609.34 // Convert to miles
        }
        
        lastLocation = location
        
        // Reset stationary timer when location updates
        if isTracking {
            stationaryStartTime = nil
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if isTracking {
                manager.startUpdatingLocation()
            }
        default:
            break
        }
    }
}

extension TrackingManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        
        // Scan for known vehicle UUIDs
        let context = persistenceController.container.viewContext
        let request = NSFetchRequest<Vehicle>(entityName: "Vehicle")
        request.predicate = NSPredicate(format: "bluetoothUUID != nil")
        
        if let vehicles = try? context.fetch(request) {
            let uuids = vehicles.compactMap { UUID(uuidString: $0.bluetoothUUID ?? "") }
            if !uuids.isEmpty {
                central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let context = persistenceController.container.viewContext
        let request = NSFetchRequest<Vehicle>(entityName: "Vehicle")
        request.predicate = NSPredicate(format: "bluetoothUUID == %@", peripheral.identifier.uuidString)
        
        if let vehicle = try? context.fetch(request).first {
            // Connect to the peripheral to monitor disconnections
            if connectedPeripherals[peripheral.identifier] == nil {
                peripheral.delegate = self
                central.connect(peripheral, options: nil)
                connectedPeripherals[peripheral.identifier] = peripheral
            }
            
            if !isTracking {
                trackedVehicleUUID = peripheral.identifier
                startTracking()
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // Peripheral connected successfully
        print("Connected to vehicle: \(peripheral.identifier)")
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectedPeripherals.removeValue(forKey: peripheral.identifier)
        print("Failed to connect: \(error?.localizedDescription ?? "Unknown error")")
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectedPeripherals.removeValue(forKey: peripheral.identifier)
        
        if peripheral.identifier == trackedVehicleUUID && isTracking {
            // Wait a bit before stopping in case of brief disconnection
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                if self.trackedVehicleUUID == peripheral.identifier {
                    self.stopTracking()
                    self.trackedVehicleUUID = nil
                }
            }
        }
    }
}

extension TrackingManager: CBPeripheralDelegate {
    // Required delegate methods for CBPeripheral
}

