import Foundation
#if canImport(Tokenizers)
import Tokenizers
#endif

public func testTokenizerLoad() async {
    #if canImport(Tokenizers)
    do {
        let url = IrisPaths.default.modelsDir.appendingPathComponent("distilbert-prompt-injection.mlmodelc")
        let _ = try await AutoTokenizer.from(modelFolder: url)
        print("Tokenizer Success")
    } catch {
        print("Tokenizer Error: \(error)")
    }
    #endif
}
