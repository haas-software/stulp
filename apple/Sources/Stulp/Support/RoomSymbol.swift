import StulpKit

/// The symbol of a place: the one the person chose (`DeviceGroup.icon`), or else one guessed from
/// its name, so floors and rooms read like Home's sidebar without anyone setting them up.
enum RoomSymbol {
    static func symbol(_ group: DeviceGroup) -> String {
        group.icon ?? name(for: group.name)
    }

    /// The guess from a name. Floors come first: "Eerste etage" must not match a room word.
    static func name(for room: String) -> String {
        let n = room.lowercased()
        let table: [(String, String)] = [
            // House is Thuis's own symbol, so the ground floor is floor 0, as "begane grond" counts.
            ("begane grond", "0.square.fill"), ("beneden", "0.square.fill"), ("parterre", "0.square.fill"),
            ("eerste", "1.square.fill"), ("1e ", "1.square.fill"),
            ("tweede", "2.square.fill"), ("2e ", "2.square.fill"),
            ("derde", "3.square.fill"), ("3e ", "3.square.fill"),
            ("kelder", "arrow.down.square.fill"), ("souterrain", "arrow.down.square.fill"),
            ("boven", "arrow.up.square.fill"), ("zolder", "house.lodge.fill"),
            ("woonkamer", "sofa.fill"), ("zitkamer", "sofa.fill"), ("living", "sofa.fill"),
            ("keuken", "fork.knife"), ("eetkamer", "fork.knife"),
            ("slaapkamer", "bed.double.fill"), ("kinderkamer", "teddybear.fill"),
            ("badkamer", "bathtub.fill"), ("douche", "shower.fill"), ("toilet", "toilet.fill"), ("wc", "toilet.fill"),
            ("tuin", "tree.fill"), ("buiten", "sun.horizon.fill"), ("terras", "chair.lounge.fill"), ("balkon", "chair.lounge.fill"),
            ("garage", "car.fill"), ("oprit", "car.fill"),
            ("kantoor", "desktopcomputer"), ("werkkamer", "desktopcomputer"), ("studeer", "desktopcomputer"),
            ("hal", "door.left.hand.closed"), ("gang", "door.left.hand.closed"), ("entree", "door.left.hand.closed"),
            ("trap", "stairs"), ("overloop", "stairs"),
            ("wasruimte", "washer.fill"), ("bijkeuken", "washer.fill"), ("berging", "cabinet.fill"), ("schuur", "cabinet.fill"),
        ]
        return table.first { n.contains($0.0) }?.1 ?? "square.split.bottomrightquarter.fill"
    }

    /// What the icon picker offers: floors first, then rooms, then outside and the rest.
    static let choices: [String] = [
        "house.fill", "0.square.fill", "1.square.fill", "2.square.fill", "3.square.fill", "4.square.fill",
        "arrow.down.square.fill", "arrow.up.square.fill", "house.lodge.fill", "stairs", "building.2.fill",
        "sofa.fill", "tv.fill", "fork.knife", "refrigerator.fill", "bed.double.fill", "teddybear.fill",
        "bathtub.fill", "shower.fill", "toilet.fill", "washer.fill", "desktopcomputer", "book.fill",
        "dumbbell.fill", "gamecontroller.fill", "music.note", "door.left.hand.closed", "cabinet.fill",
        "wrench.and.screwdriver.fill", "server.rack", "car.fill", "door.garage.closed", "bicycle",
        "tree.fill", "leaf.fill", "chair.lounge.fill", "sun.horizon.fill", "tent.fill", "pawprint.fill",
        "square.split.bottomrightquarter.fill",
    ]
}
