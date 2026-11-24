// Dynamically linked against libcrypto.so, libssl.so and libz.so from the
// openssl and zlib-shared packages. Run by net-crypto.c.
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509_vfy.h>
#include <stdio.h>
#include <string.h>
#include <zlib.h>

static int fail(const char *what)
{
    printf("FAIL %s\n", what);
    return 1;
}

int main(void)
{
    printf("%s\n", OpenSSL_version(OPENSSL_VERSION));

    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int length = 0;
    if (!EVP_Digest("abc", 3, digest, &length, EVP_sha256(), NULL) || length != 32) {
        return fail("EVP_Digest");
    }
    char hex[65];
    for (unsigned int i = 0; i < length; ++i) { sprintf(hex + 2 * i, "%02x", digest[i]); }
    printf("sha256(abc)=%s\n", hex);
    if (strcmp(hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")) {
        return fail("sha256 value");
    }

    unsigned char first[32], second[32], zero[32] = {0};
    if (RAND_bytes(first, 32) != 1 || RAND_bytes(second, 32) != 1) { return fail("RAND_bytes"); }
    if (!memcmp(first, second, 32) || !memcmp(first, zero, 32)) { return fail("RAND_bytes repeat"); }
    for (int i = 0; i < 32; ++i) { sprintf(hex + 2 * i, "%02x", first[i]); }
    printf("rand=%s\n", hex);

    // The CA bundle loads, and OpenSSL's default file finds it.
    X509_STORE *store = X509_STORE_new();
    if (!store || X509_STORE_load_file(store, "/etc/ssl/certs/ca-certificates.crt") != 1) {
        return fail("load CA bundle");
    }
    int count = sk_X509_OBJECT_num(X509_STORE_get0_objects(store));
    printf("CA certificates=%d\n", count);
    if (count < 100) { return fail("CA count"); }
    X509_STORE_free(store);
    printf("default cert file=%s\n", X509_get_default_cert_file());

    SSL_CTX *context = SSL_CTX_new(TLS_client_method());
    if (!context) { return fail("SSL_CTX_new"); }
    if (SSL_CTX_set_default_verify_paths(context) != 1) { return fail("default verify paths"); }
    SSL *ssl = SSL_new(context);
    if (!ssl) { return fail("SSL_new"); }
    SSL_free(ssl);
    SSL_CTX_free(context);

    // zlib-shared round trip.
    static unsigned char text[65536], packed[70000], unpacked[65536];
    for (unsigned i = 0; i < sizeof text; ++i) { text[i] = "acpi-kernel "[i % 12]; }
    uLongf packed_length = sizeof packed, unpacked_length = sizeof unpacked;
    if (compress(packed, &packed_length, text, sizeof text) != Z_OK) { return fail("compress"); }
    if (uncompress(unpacked, &unpacked_length, packed, packed_length) != Z_OK ||
        unpacked_length != sizeof text || memcmp(text, unpacked, sizeof text)) {
        return fail("uncompress");
    }
    printf("zlib %s 65536 -> %lu bytes\n", zlibVersion(), (unsigned long)packed_length);
    printf("crypto-probe ok\n");
    return 0;
}
