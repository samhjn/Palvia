import Foundation
import NaturalLanguage

/// On-device sentence/word embedding using Apple NaturalLanguage framework.
/// Preferred over cloud embeddings — free, fast, works offline.
final class LocalEmbeddingService {

    /// Compute a vector for the given text.
    /// Tries sentence embedding first, falls back to averaged word vectors.
    func embed(text: String) -> [Float]? {
        let language = detectLanguage(text)

        // 1) Try sentence embedding (iOS 17+, best quality)
        if let sentenceEmb = NLEmbedding.sentenceEmbedding(for: language),
           let vec = sentenceEmb.vector(for: text) {
            return vec.map { Float($0) }
        }

        // 2) Fall back to averaged word vectors
        if let wordEmb = NLEmbedding.wordEmbedding(for: language) {
            if let vec = averageWordVectors(text: text, embedding: wordEmb) {
                return vec
            }
        }

        // 3) If detected language failed, try English as last resort
        if language != .english {
            if let sentenceEmb = NLEmbedding.sentenceEmbedding(for: .english),
               let vec = sentenceEmb.vector(for: text) {
                return vec.map { Float($0) }
            }
            if let wordEmb = NLEmbedding.wordEmbedding(for: .english) {
                if let vec = averageWordVectors(text: text, embedding: wordEmb) {
                    return vec
                }
            }
        }

        return nil
    }

    /// Dimension of the embedding vectors produced for a given language.
    func dimension(for language: NLLanguage = .english) -> Int? {
        if let emb = NLEmbedding.sentenceEmbedding(for: language) {
            return emb.dimension
        }
        if let emb = NLEmbedding.wordEmbedding(for: language) {
            return emb.dimension
        }
        return nil
    }

    // MARK: - Private

    private func detectLanguage(_ text: String) -> NLLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(500)))
        return recognizer.dominantLanguage ?? .english
    }

    private func averageWordVectors(text: String, embedding: NLEmbedding) -> [Float]? {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        let dim = embedding.dimension

        var sum = [Double](repeating: 0.0, count: dim)
        var count = 0

        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range])
            if let vec = embedding.vector(for: word) {
                for i in 0..<dim {
                    sum[i] += vec[i]
                }
                count += 1
            }
            return true
        }

        guard count > 0 else { return nil }

        // Average and normalize
        let invCount = 1.0 / Double(count)
        var result = sum.map { Float($0 * invCount) }

        // L2 normalize
        var norm: Float = 0
        for v in result { norm += v * v }
        norm = sqrt(norm)
        if norm > 0 {
            for i in 0..<result.count { result[i] /= norm }
        }

        return result
    }
}
