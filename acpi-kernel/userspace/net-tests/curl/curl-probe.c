// Fetches a URL with the libcurl API and prints the body, the HTTP status
// and the TLS backend: curl-probe <url> <ca file>
#include <curl/curl.h>
#include <stdio.h>

static size_t write_body(char *data, size_t size, size_t count, void *user)
{
    (void)user;
    return fwrite(data, size, count, stdout) * size;
}

int main(int argc, char **argv)
{
    if (argc != 3) { return 2; }
    if (curl_global_init(CURL_GLOBAL_DEFAULT)) { return 1; }
    curl_version_info_data *info = curl_version_info(CURLVERSION_NOW);
    printf("libcurl %s ssl %s\n", info->version, info->ssl_version);
    CURL *handle = curl_easy_init();
    if (!handle) { return 1; }
    curl_easy_setopt(handle, CURLOPT_URL, argv[1]);
    curl_easy_setopt(handle, CURLOPT_CAINFO, argv[2]);
    curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, write_body);
    CURLcode result = curl_easy_perform(handle);
    long code = 0;
    curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &code);
    printf("curl-probe result=%d status=%ld\n", result, code);
    curl_easy_cleanup(handle);
    curl_global_cleanup();
    return result == CURLE_OK && code == 200 ? 0 : 1;
}
