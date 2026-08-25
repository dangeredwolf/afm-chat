import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing

struct Gemma3nKVCacheTests {
    @Test("Gemma3nText handles quantized KV cache after prefill")
    func quantizedKVCacheSupportsFullAttention() throws {
        let model = Gemma3nTextModel(config: try Self.configuration(sharedKVLayers: 0))
        eval(model)

        var cache: [KVCache] = try model.newCache(parameters: nil)
        let promptLogits = model(MLXArray([1, 2, 3]).reshaped([1, 3]), cache: cache)
        eval(promptLogits)
        #expect(promptLogits.shape == [1, 3, 32])

        maybeQuantizeKVCache(cache: &cache, kvBits: 4, kvGroupSize: 64, quantizedKVStart: 0)
        #expect(cache.contains { $0 is QuantizedKVCache })

        let nextLogits = model(MLXArray([4]).reshaped([1, 1]), cache: cache)
        eval(nextLogits)
        #expect(nextLogits.shape == [1, 1, 32])
    }

    @Test("Gemma3nText handles quantized KV cache in shared full attention")
    func quantizedKVCacheSupportsSharedFullAttention() throws {
        let model = Gemma3nTextModel(config: try Self.configuration(sharedKVLayers: 2))
        eval(model)

        var cache: [KVCache] = try model.newCache(parameters: nil)
        let promptLogits = model(MLXArray([1, 2, 3]).reshaped([1, 3]), cache: cache)
        eval(promptLogits)
        #expect(promptLogits.shape == [1, 3, 32])

        maybeQuantizeKVCache(cache: &cache, kvBits: 4, kvGroupSize: 64, quantizedKVStart: 0)
        #expect(cache.contains { $0 is QuantizedKVCache })

        let nextLogits = model(MLXArray([4]).reshaped([1, 1]), cache: cache)
        eval(nextLogits)
        #expect(nextLogits.shape == [1, 1, 32])
    }

    private static func configuration(sharedKVLayers: Int) throws -> Gemma3nTextConfiguration {
        let layerCount = sharedKVLayers > 0 ? 4 : 2
        let layerTypes =
            sharedKVLayers > 0
            ? #"["sliding_attention", "full_attention", "sliding_attention", "full_attention"]"#
            : #"["sliding_attention", "full_attention"]"#
        let sparsity = Array(repeating: "0", count: layerCount).joined(separator: ", ")
        let json = """
            {
              "model_type": "gemma3n",
              "hidden_size": 32,
              "num_hidden_layers": \(layerCount),
              "intermediate_size": 64,
              "num_attention_heads": 2,
              "head_dim": 32,
              "rms_norm_eps": 0.000001,
              "vocab_size": 32,
              "num_key_value_heads": 1,
              "num_kv_shared_layers": \(sharedKVLayers),
              "vocab_size_per_layer_input": 32,
              "sliding_window": 8,
              "max_position_embeddings": 64,
              "rope_local_base_freq": 10000,
              "rope_theta": 1000000,
              "final_logit_softcapping": 30.0,
              "layer_types": \(layerTypes),
              "activation_sparsity_pattern": [\(sparsity)],
              "hidden_size_per_layer_input": 16,
              "altup_num_inputs": 2,
              "altup_correct_scale": true,
              "altup_active_idx": 0,
              "laurel_rank": 8
            }
            """
        return try JSONDecoder().decode(
            Gemma3nTextConfiguration.self, from: Data(json.utf8))
    }
}
