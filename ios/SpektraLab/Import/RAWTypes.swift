//  RAWTypes.swift — every camera maker's RAW, as this app types it. iOS knows most makers' RAW extensions; the
//  rest (Pentax PTX, Mamiya MEF, Sigma X3F, Kodak KDC/DCS/K25, Phase One CAP/EIP, Casio BAY, Minolta MDC, Rawzor
//  RWZ) are declared in Info.plist (`UTImportedTypeDeclarations`) as camera RAW, so the pickers offer them and
//  they decode through LibRaw. GoPro's GPR is known to iOS but not as RAW: it is a DNG, so it is typed as one.

import UniformTypeIdentifiers

enum RAWTypes {
    /// The type a file is imported as, from its extension: a RAW type wherever the file is a camera RAW.
    static func hint(forExtension ext: String) -> UTType? {
        if ext.lowercased() == "gpr" { return UTType("com.adobe.raw-image") }
        return UTType(filenameExtension: ext)
    }

    /// Whether a file is a picture this app imports (an image or any camera RAW).
    static func isPicture(_ url: URL) -> Bool {
        guard let t = hint(forExtension: url.pathExtension) else { return false }
        return t.conforms(to: .image) || t.conforms(to: .rawImage)
    }
}
