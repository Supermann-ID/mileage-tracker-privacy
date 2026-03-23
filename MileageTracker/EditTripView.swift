import SwiftUI
import CoreData

struct EditTripView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    
    @ObservedObject var trip: Trip
    
    @State private var date: Date
    @State private var startOdometer: String
    @State private var endOdometer: String
    @State private var purpose: String?
    @State private var customPurpose = ""
    @State private var notes: String
    @State private var selectedCategory: TripCategory
    @State private var selectedVehicle: Vehicle?
    
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Vehicle.name, ascending: true)])
    private var vehicles: FetchedResults<Vehicle>
    
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Purpose.lastUsed, ascending: false)])
    private var purposes: FetchedResults<Purpose>
    
    private let commonPurposes = [
        "Client Meeting",
        "Site Visit / Inspection",
        "Delivery / Pickup",
        "Business Errand",
        "Training / Conference",
        "Office Visit",
        "Equipment Transport",
        "Home Office to Business PO Box",
        "Other Business"
    ]
    
    private var recentPurposes: [String] {
        Array(purposes.prefix(5).map { $0.text })
    }
    
    private var allPurposeOptions: [String] {
        var options = recentPurposes
        for purpose in commonPurposes where !options.contains(purpose) {
            options.append(purpose)
        }
        return options
    }
    
    init(trip: Trip) {
        self.trip = trip
        _date = State(initialValue: trip.date)
        _startOdometer = State(initialValue: String(format: "%.1f", trip.startOdometer))
        _endOdometer = State(initialValue: String(format: "%.1f", trip.endOdometer))
        
        // Handle purpose: if it's not in common/recent purposes, treat as custom
        let tripPurpose = trip.purpose
        let commonPurposes = [
            "Client Meeting", "Site Visit / Inspection", "Delivery / Pickup",
            "Business Errand", "Training / Conference", "Office Visit",
            "Equipment Transport", "Home Office to Business PO Box", "Other Business"
        ]
        let isCustomPurpose = tripPurpose != nil && !commonPurposes.contains(tripPurpose!)
        
        if isCustomPurpose {
            _purpose = State(initialValue: "CUSTOM")
            _customPurpose = State(initialValue: tripPurpose ?? "")
        } else {
            _purpose = State(initialValue: tripPurpose)
            _customPurpose = State(initialValue: "")
        }
        
        _notes = State(initialValue: trip.notes ?? "")
        _selectedCategory = State(initialValue: trip.tripCategory)
        _selectedVehicle = State(initialValue: trip.vehicle)
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section("Trip Details") {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    
                    HStack {
                        Text("Start Odometer")
                        Spacer()
                        TextField("0.0", text: $startOdometer)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                    }
                    
                    HStack {
                        Text("End Odometer")
                        Spacer()
                        TextField("0.0", text: $endOdometer)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                    }
                }
                
                Section("Business Purpose") {
                    Picker("Purpose", selection: $purpose) {
                        Text("None").tag(nil as String?)
                        ForEach(allPurposeOptions, id: \.self) { option in
                            Text(option).tag(option as String?)
                        }
                        Text("Custom...").tag("CUSTOM" as String?)
                    }
                    
                    if purpose == "CUSTOM" {
                        TextField("Enter custom purpose", text: $customPurpose)
                    }
                }
                
                Section("Category") {
                    Picker("Category", selection: $selectedCategory) {
                        ForEach(TripCategory.allCases, id: \.self) { category in
                            HStack {
                                Text(category.displayName)
                                Spacer()
                                Text(category.rateDescription)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .tag(category)
                        }
                    }
                }
                
                Section("Additional Info") {
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                    
                    Picker("Vehicle", selection: $selectedVehicle) {
                        Text("None").tag(nil as Vehicle?)
                        ForEach(vehicles) { vehicle in
                            Text(vehicle.name ?? "Unknown").tag(vehicle as Vehicle?)
                        }
                    }
                }
            }
            .navigationTitle("Edit Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveTrip()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }
    
    private var isValid: Bool {
        guard let start = Double(startOdometer),
              let end = Double(endOdometer),
              end >= start else {
            return false
        }
        return true
    }
    
    private func saveTrip() {
        guard let start = Double(startOdometer),
              let end = Double(endOdometer) else {
            return
        }
        
        trip.date = date
        trip.startOdometer = start
        trip.endOdometer = end
        trip.category = selectedCategory.rawValue
        trip.notes = notes.isEmpty ? nil : notes
        trip.vehicle = selectedVehicle
        
        let finalPurpose: String?
        if purpose == "CUSTOM" {
            finalPurpose = customPurpose.isEmpty ? nil : customPurpose
        } else {
            finalPurpose = purpose
        }
        trip.purpose = finalPurpose
        
        // Update or create Purpose entity for recent purposes
        if let finalPurpose = finalPurpose {
            let request = NSFetchRequest<Purpose>(entityName: "Purpose")
            request.predicate = NSPredicate(format: "text == %@", finalPurpose)
            
            if let existingPurpose = try? viewContext.fetch(request).first {
                existingPurpose.lastUsed = Date()
            } else {
                let newPurpose = Purpose(context: viewContext)
                newPurpose.text = finalPurpose
                newPurpose.lastUsed = Date()
            }
        }
        
        do {
            try viewContext.save()
            dismiss()
        } catch {
            let nsError = error as NSError
            fatalError("Unresolved error \(nsError), \(nsError.userInfo)")
        }
    }
}

