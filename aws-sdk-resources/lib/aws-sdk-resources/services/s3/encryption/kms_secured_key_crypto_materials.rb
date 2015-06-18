require 'base64'

module Aws
  module S3
    module Encryption
      # @api private
      class KmsSecuredKeyCryptoMaterials

        def initialize(options = {})
          @kms_key_id = options[:kms_key_id]
          @kms_client = options[:kms_client]
        end

        # @return [Array<Hash,Cipher>] Creates an returns a new encryption
        #   envelope and encryption cipher.
        def for_encyrption
          encryption_context = { "kms_cmk_id" => @kms_key_id }
          key_data = @kms_client.generate_data_key(
            key_id: @kms_key_id,
            encryption_context: encryption_context,
            key_spec: 'AES_256',
          )
          cipher = Utils.aes_encryption_cipher(:CBC)
          cipher.key = key_data.plaintext
          envelope = {
            'x-amz-key-v2' => encode64(key_data.ciphertext_blob),
            'x-amz-iv' => encode64(cipher.iv = cipher.random_iv),
            'x-amz-cek-alg' => 'AES/CBC/PKCS5Padding',
            'x-amz-wrap-alg' => 'kms',
            'x-amz-matdesc' => Json.dump(encryption_context)
          }
          [envelope, cipher]
        end

        # @return [Cipher] Given an encryption envelope, returns a
        #   decryption cipher.
        def for_decryption(envelope)
          encryption_context = Json.load(envelope['x-amz-matdesc'])
          key = @kms_client.decrypt(
            ciphertext_blob: decode64(envelope['x-amz-key']),
            encryption_context: encryption_context,
          ).plaintext
          iv = decode64(envelope['x-amz-iv'])
          Utils.aes_decryption_cipher(:CBC, key, iv)
        end

        private

        def encode64(str)
          Base64.encode64(str).split("\n") * ""
        end

        def decode64(str)
          Base64.decode64(str)
        end

      end
    end
  end
end