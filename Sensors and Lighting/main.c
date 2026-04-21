#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <inttypes.h>
#include <stdbool.h>
#include <math.h>
#include <time.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/event_groups.h"
#include "freertos/semphr.h"
#include "freertos/queue.h"

#include "esp_log.h"
#include "esp_err.h"
#include "esp_system.h"
#include "esp_event.h"
#include "esp_wifi.h"
#include "esp_netif.h"
#include "esp_http_client.h"
#include "esp_http_server.h"
#include "esp_crt_bundle.h"
#include "esp_sntp.h"
#include "esp_timer.h"
#include "esp_netif_sntp.h"

#include "nvs.h"
#include "nvs_flash.h"

#include "lwip/inet.h"
#include "lwip/ip4_addr.h"
#include "lwip/err.h"
#include "lwip/sys.h"

#include "driver/gpio.h"
#include "driver/i2c.h"
#include "cJSON.h"

// ===================== USER CONFIG =====================

// Firebase Identity Toolkit (Web API key)
#define FB_API_KEY         "AIzaSyDgSkrLrTaDiQ1wu-b71shYqSTV69_YokA"

// RTDB base (NO trailing slash)
#define FB_RTDB_BASE       "https://solar-home-lighting-1-default-rtdb.firebaseio.com"

// Firebase user creds (CHANGE PASSWORD ASAP)
#define FB_EMAIL           "matthew.cepulis@gmail.com"
#define FB_PASSWORD        "403404"

// UID that matches your rules path
#define FB_UID             "8BRff9bNFHPxHjtkJ93Z71WcqYA2"

// Wi-Fi setup AP
#define SETUP_AP_SSID      "SolarLightingSetup"
#define SETUP_AP_PASS      ""            // open
#define SETUP_AP_CHANNEL   6

// Retry logic
#define WIFI_CONNECT_MAX_TRIES   10

// Tasks
#define TASK_STACK_SENSORS   6144
#define TASK_STACK_LIGHTS    6144

// ===================== GPIO MAP (YOUR PCB) =====================

// I2C (OPT3001)
#define GPIO_I2C_SDA   8
#define GPIO_I2C_SCL   9

// OPT3001 pins
#define GPIO_OPT_INT   36
#define GPIO_OPT_ADR   35
#define OPT_ADR_LEVEL  0

// PIR
#define GPIO_PIR_OUT   41

// Lights (LIGHT1/LIGHT2 = inside, LIGHT3/LIGHT4 = outside/auto)
#define GPIO_LIGHT1    40
#define GPIO_LIGHT2    39
#define GPIO_LIGHT3    38
#define GPIO_LIGHT4    37

// ===================== OPT3001 CONFIG =====================

#define I2C_PORT       I2C_NUM_0
#define I2C_FREQ_HZ    100000

#define OPT3001_ADDR0  0x44
#define OPT3001_ADDR1  0x45

#define OPT3001_REG_RESULT  0x00
#define OPT3001_REG_CONFIG  0x01

// ===================== TIMING =====================

// How fast the PIR GPIO is sampled
#define MOTION_POLL_MS          20

// How long motion stays true after the PIR pin last went LOW (i.e. after the last
// detection ends). The countdown starts when the PIR goes quiet — not when it last
// fired. This means frequent re-triggers while someone is present keep the lights on,
// and the hold only expires once the PIR has been continuously low for this window.
#define MOTION_HOLD_MS          3000

// Lux uploaded to Firebase every 30 seconds
#define LUX_UPLOAD_INTERVAL_MS  30000

// How fast lightingControls is polled from Firebase (manual app changes)
#define LIGHTS_POLL_MS          150

// How often settings (nightLightPref) are refreshed from Firebase
#define SETTINGS_POLL_MS        3000

// How often humanActivity/detected is refreshed (only needed for mode 2)
#define HUMAN_POLL_MS           500

// Task stack sizes
#define TASK_STACK_MOTION_FB    4096

// ===================== LOG =====================

static const char *TAG = "SOLAR_LIGHTING";

// ===================== GLOBALS =====================

static EventGroupHandle_t s_wifi_event_group;
static const int WIFI_CONNECTED_BIT = BIT0;

static char g_wifi_ssid[33] = {0};
static char g_wifi_pass[65] = {0};

static char g_id_token[2048] = {0};
static char g_refresh_token[2048] = {0};
static char g_local_id[128] = {0};

static int g_opt_addr = OPT3001_ADDR0;

// Netif/eventloop/wifi init guards (fixes ESP_ERR_INVALID_STATE)
static bool s_netif_inited = false;
static bool s_event_loop_created = false;
static bool s_wifi_inited = false;
static esp_netif_t *s_sta_netif = NULL;
static esp_netif_t *s_ap_netif  = NULL;

// ===================== SHARED STATE (protected by mutex) =====================
// Shared between sensor task and lights task for automation logic.

static SemaphoreHandle_t g_state_mutex = NULL;

// Latest sensor readings
static float   g_lux           = NAN;   // current lux (updated every 30s upload)
static int     g_motion        = 0;     // 1 = motion detected
static int     g_is_night      = 0;     // 1 = lux < 10

// Settings fetched from Firebase
static int     g_night_light_pref = 0;  // 0, 1, or 2
static bool    g_human_detected   = false;

// Current desired state of outside lights (LIGHT3/LIGHT4) driven by automation
// -1 = not yet set, 0 = off, 1 = on
static int     g_auto_light3 = -1;
static int     g_auto_light4 = -1;

// Firebase-fetched lightingControls values, written by task_firebase, read by task_auto_gpio.
// -1 = not yet received. Updated whenever lightingControls is polled.
static int     g_fb_light1 = -1;
static int     g_fb_light2 = -1;
static int     g_fb_light3 = -1;   // only applied to GPIO in mode 0
static int     g_fb_light4 = -1;

// Queue used to hand motion-change payloads to task_firebase.
// MUST be depth 1 — xQueueOverwrite requires length == 1 so only the latest
// motion state is ever pending (no stale events piling up).
#define MOTION_FB_QUEUE_DEPTH  1
#define MOTION_FB_BODY_LEN     64
static QueueHandle_t g_motion_fb_queue = NULL;

// Queue used to hand outside-light state changes to task_firebase for writing.
// Depth 1 + xQueueOverwrite: only the latest desired state is ever written.
typedef struct { int l3; int l4; } lights_fb_msg_t;
static QueueHandle_t g_lights_fb_queue = NULL;

// ===================== SMALL UTIL =====================

static void safe_strncpy(char *dst, const char *src, size_t dst_sz) {
    if (!dst || dst_sz == 0) return;
    if (!src) { dst[0] = 0; return; }
    strlcpy(dst, src, dst_sz);
}

// ===================== NVS WIFI CREDS =====================

static esp_err_t nvs_load_wifi_creds(void) {
    nvs_handle_t nvs;
    esp_err_t err = nvs_open("wifi", NVS_READONLY, &nvs);
    if (err != ESP_OK) return err;

    size_t ssid_len = sizeof(g_wifi_ssid);
    size_t pass_len = sizeof(g_wifi_pass);

    err = nvs_get_str(nvs, "ssid", g_wifi_ssid, &ssid_len);
    if (err == ESP_OK) {
        err = nvs_get_str(nvs, "pass", g_wifi_pass, &pass_len);
        if (err != ESP_OK) g_wifi_pass[0] = 0;
    }
    nvs_close(nvs);
    return err;
}

static esp_err_t nvs_save_wifi_creds(const char *ssid, const char *pass) {
    nvs_handle_t nvs;
    esp_err_t err = nvs_open("wifi", NVS_READWRITE, &nvs);
    if (err != ESP_OK) return err;

    err = nvs_set_str(nvs, "ssid", ssid);
    if (err == ESP_OK) err = nvs_set_str(nvs, "pass", pass ? pass : "");
    if (err == ESP_OK) err = nvs_commit(nvs);
    nvs_close(nvs);

    if (err != ESP_OK) return err;

    safe_strncpy(g_wifi_ssid, ssid, sizeof(g_wifi_ssid));
    safe_strncpy(g_wifi_pass, pass ? pass : "", sizeof(g_wifi_pass));
    return ESP_OK;
}

static void nvs_clear_wifi_creds(void) {
    nvs_handle_t nvs;
    if (nvs_open("wifi", NVS_READWRITE, &nvs) == ESP_OK) {
        nvs_erase_key(nvs, "ssid");
        nvs_erase_key(nvs, "pass");
        nvs_commit(nvs);
        nvs_close(nvs);
    }
    g_wifi_ssid[0] = 0;
    g_wifi_pass[0] = 0;
}

// ===================== WIFI EVENT HANDLER =====================

static void wifi_event_handler(void *arg, esp_event_base_t event_base,
                               int32_t event_id, void *event_data) {
    (void)arg;

    if (event_base == WIFI_EVENT) {
        if (event_id == WIFI_EVENT_STA_START) {
            esp_wifi_connect();
        } else if (event_id == WIFI_EVENT_STA_DISCONNECTED) {
            xEventGroupClearBits(s_wifi_event_group, WIFI_CONNECTED_BIT);
        }
    } else if (event_base == IP_EVENT) {
        if (event_id == IP_EVENT_STA_GOT_IP) {
            ip_event_got_ip_t *event = (ip_event_got_ip_t *)event_data;
            ESP_LOGI(TAG, "Got IP: " IPSTR, IP2STR(&event->ip_info.ip));
            xEventGroupSetBits(s_wifi_event_group, WIFI_CONNECTED_BIT);
        }
    }
}

// ===================== CORE INIT (ONCE) =====================

static void netif_eventloop_init_once(void) {
    if (!s_netif_inited) {
        ESP_ERROR_CHECK(esp_netif_init());
        s_netif_inited = true;
    }
    if (!s_event_loop_created) {
        esp_err_t err = esp_event_loop_create_default();
        if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
            ESP_ERROR_CHECK(err);
        }
        s_event_loop_created = true;
    }
}

static void wifi_init_once(void) {
    netif_eventloop_init_once();

    if (!s_wifi_event_group) {
        s_wifi_event_group = xEventGroupCreate();
    }

    if (!s_sta_netif) s_sta_netif = esp_netif_create_default_wifi_sta();
    if (!s_ap_netif)  s_ap_netif  = esp_netif_create_default_wifi_ap();

    if (!s_wifi_inited) {
        wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
        ESP_ERROR_CHECK(esp_wifi_init(&cfg));

        ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, &wifi_event_handler, NULL));
        ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, &wifi_event_handler, NULL));

        s_wifi_inited = true;
    }
}

static bool wifi_wait_connected_ms(int timeout_ms) {
    EventBits_t bits = xEventGroupWaitBits(
        s_wifi_event_group,
        WIFI_CONNECTED_BIT,
        pdFALSE,
        pdTRUE,
        pdMS_TO_TICKS(timeout_ms)
    );
    return (bits & WIFI_CONNECTED_BIT) != 0;
}

// ===================== DNS FALLBACK (OPTIONAL) =====================

static void set_dns_8888(void) {
    esp_netif_t *netif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
    if (!netif) return;

    esp_netif_dns_info_t dns;
    memset(&dns, 0, sizeof(dns));
    dns.ip.u_addr.ip4.addr = ipaddr_addr("8.8.8.8");
    dns.ip.type = ESP_IPADDR_TYPE_V4;

    esp_err_t err = esp_netif_set_dns_info(netif, ESP_NETIF_DNS_MAIN, &dns);
    ESP_LOGI(TAG, "DNS set 8.8.8.8 -> %s", esp_err_to_name(err));
}

// ===================== WIFI START (STA/AP SWITCHING) =====================

static esp_err_t wifi_start_sta_only(void) {
    wifi_init_once();

    wifi_config_t sta = {0};
    safe_strncpy((char *)sta.sta.ssid, g_wifi_ssid, sizeof(sta.sta.ssid));
    safe_strncpy((char *)sta.sta.password, g_wifi_pass, sizeof(sta.sta.password));

    if (strlen(g_wifi_pass) == 0) {
        sta.sta.threshold.authmode = WIFI_AUTH_OPEN;
        sta.sta.pmf_cfg.capable = false;
        sta.sta.pmf_cfg.required = false;
        ESP_LOGW(TAG, "Connecting to OPEN Wi-Fi (no password). SSID='%s'", g_wifi_ssid);
    } else {
        sta.sta.threshold.authmode = WIFI_AUTH_WPA_WPA2_PSK;
        sta.sta.pmf_cfg.capable = true;
        sta.sta.pmf_cfg.required = false;
        ESP_LOGI(TAG, "Connecting to secured Wi-Fi. SSID='%s'", g_wifi_ssid);
    }

    ESP_ERROR_CHECK(esp_wifi_stop());
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &sta));
    ESP_ERROR_CHECK(esp_wifi_start());
    return ESP_OK;
}

static esp_err_t wifi_start_setup_ap(void) {
    wifi_init_once();

    wifi_config_t ap = {0};
    safe_strncpy((char *)ap.ap.ssid, SETUP_AP_SSID, sizeof(ap.ap.ssid));
    ap.ap.ssid_len = strlen(SETUP_AP_SSID);
    safe_strncpy((char *)ap.ap.password, SETUP_AP_PASS, sizeof(ap.ap.password));
    ap.ap.channel = SETUP_AP_CHANNEL;
    ap.ap.max_connection = 4;
    ap.ap.authmode = (strlen(SETUP_AP_PASS) == 0) ? WIFI_AUTH_OPEN : WIFI_AUTH_WPA2_PSK;

    ESP_ERROR_CHECK(esp_wifi_stop());
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_AP));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP, &ap));
    ESP_ERROR_CHECK(esp_wifi_start());

    ESP_LOGW(TAG, "Entering SETUP MODE (AP + web page)");
    ESP_LOGI(TAG, "Setup AP running SSID=%s PASS=%s", SETUP_AP_SSID, SETUP_AP_PASS);
    ESP_LOGI(TAG, "Setup page: connect to AP '%s' then browse to http://192.168.4.1/", SETUP_AP_SSID);
    return ESP_OK;
}

// ===================== SETUP WEB SERVER =====================

static httpd_handle_t s_httpd = NULL;

static const char *SETUP_HTML =
"<!doctype html><html><head><meta charset='utf-8'/>"
"<meta name='viewport' content='width=device-width, initial-scale=1'/>"
"<title>Solar Lighting Setup</title></head>"
"<body style='font-family:Arial;max-width:520px;margin:40px auto;'>"
"<h2>Wi-Fi Setup</h2>"
"<p>Enter your Wi-Fi network credentials.</p>"
"<form method='POST' action='/save'>"
"<label>SSID</label><br/><input name='ssid' style='width:100%;padding:10px' required/><br/><br/>"
"<label>Password</label><br/><input name='pass' type='password' style='width:100%;padding:10px'/>"
"<p style='color:#555;margin-top:6px'>Leave blank for open (no-password) networks.</p>"
"<button style='padding:12px 18px'>Save & Reboot</button>"
"</form>"
"</body></html>";

static esp_err_t http_root_get_handler(httpd_req_t *req) {
    httpd_resp_set_type(req, "text/html");
    httpd_resp_send(req, SETUP_HTML, HTTPD_RESP_USE_STRLEN);
    return ESP_OK;
}

static void url_decode_inplace(char *dst, size_t dst_sz, const char *src) {
    if (!dst || dst_sz == 0) return;
    dst[0] = 0;
    if (!src) return;

    size_t di = 0;
    for (size_t si = 0; src[si] && di + 1 < dst_sz; ) {
        char c = src[si];
        if (c == '+') {
            dst[di++] = ' ';
            si++;
        } else if (c == '%' && src[si+1] && src[si+2]) {
            char hex[3] = { src[si+1], src[si+2], 0 };
            dst[di++] = (char) strtol(hex, NULL, 16);
            si += 3;
        } else {
            dst[di++] = c;
            si++;
        }
    }
    dst[di] = 0;
}

static bool form_get_value(const char *body, const char *key,
                                 char *out, size_t out_sz)
{
    if (!body || !key || !out || out_sz == 0) return false;

    size_t keylen = strlen(key);
    const char *p = body;

    while (*p) {
        const char *start = p;

        const char *amp = strchr(start, '&');
        size_t tok_len = amp ? (size_t)(amp - start) : strlen(start);

        const char *eq = memchr(start, '=', tok_len);
        if (eq) {
            size_t klen = (size_t)(eq - start);
            if (klen == keylen && strncmp(start, key, keylen) == 0) {
                const char *v = eq + 1;
                size_t vlen = tok_len - (size_t)(v - start);

                char tmp[256];
                if (vlen >= sizeof(tmp)) vlen = sizeof(tmp) - 1;
                memcpy(tmp, v, vlen);
                tmp[vlen] = 0;

                url_decode_inplace(out, out_sz, tmp);
                return true;
            }
        }

        if (!amp) break;
        p = amp + 1;
    }

    return false;
}

static esp_err_t http_save_post_handler(httpd_req_t *req) {
    int total = req->content_len;
    if (total <= 0 || total > 512) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Bad content length");
        return ESP_OK;
    }

    char *buf = calloc(1, total + 1);
    if (!buf) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "OOM");
        return ESP_OK;
    }

    int received = 0;
    while (received < total) {
        int r = httpd_req_recv(req, buf + received, total - received);
        if (r <= 0) {
            free(buf);
            httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "recv fail");
            return ESP_OK;
        }
        received += r;
    }
    buf[total] = 0;

    char ssid[33] = {0};
    char pass[65] = {0};

    bool ok_ssid = form_get_value(buf, "ssid", ssid, sizeof(ssid));
    bool ok_pass = form_get_value(buf, "pass", pass, sizeof(pass));
    free(buf);

    if (!ok_ssid || strlen(ssid) == 0) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Missing SSID");
        return ESP_OK;
    }
    if (!ok_pass) pass[0] = 0;

    ESP_LOGI(TAG, "Saving Wi-Fi SSID='%s' (pass len=%d)", ssid, (int)strlen(pass));

    esp_err_t err = nvs_save_wifi_creds(ssid, pass);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "NVS save failed: %s", esp_err_to_name(err));
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "NVS save failed");
        return ESP_OK;
    }

    char verify_ssid[33] = {0};
    char verify_pass[65] = {0};
    safe_strncpy(verify_ssid, g_wifi_ssid, sizeof(verify_ssid));
    safe_strncpy(verify_pass, g_wifi_pass, sizeof(verify_pass));
    ESP_LOGI(TAG, "Verified saved creds: SSID='%s' pass_len=%d", verify_ssid, (int)strlen(verify_pass));

    httpd_resp_sendstr(req, "Saved. Rebooting...");
    vTaskDelay(pdMS_TO_TICKS(400));
    esp_restart();
    return ESP_OK;
}

static void http_server_start(void) {
    if (s_httpd) return;

    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.stack_size = 6144;
    config.max_uri_handlers = 8;

    if (httpd_start(&s_httpd, &config) != ESP_OK) {
        ESP_LOGE(TAG, "Failed to start http server");
        s_httpd = NULL;
        return;
    }

    httpd_uri_t root = {
        .uri = "/",
        .method = HTTP_GET,
        .handler = http_root_get_handler,
        .user_ctx = NULL
    };
    httpd_register_uri_handler(s_httpd, &root);

    httpd_uri_t save = {
        .uri = "/save",
        .method = HTTP_POST,
        .handler = http_save_post_handler,
        .user_ctx = NULL
    };
    httpd_register_uri_handler(s_httpd, &save);
}

// ===================== SNTP =====================

static void sntp_time_sync(void) {
    ESP_LOGI(TAG, "SNTP sync...");

    esp_sntp_config_t config = ESP_NETIF_SNTP_DEFAULT_CONFIG("pool.ntp.org");
    config.sync_cb = NULL;
    esp_netif_sntp_init(&config);

    for (int i = 0; i < 20; i++) {
        time_t now = 0;
        time(&now);
        if (now > 1700000000) {
            ESP_LOGI(TAG, "Time synced.");
            return;
        }
        vTaskDelay(pdMS_TO_TICKS(500));
    }

    ESP_LOGW(TAG, "SNTP sync timeout (continuing anyway)");
}

// ===================== HTTP CLIENT (ACCUMULATE RESPONSE) =====================

typedef struct {
    char *buf;
    int len;
    int cap;
} resp_accum_t;

static esp_err_t http_event_handler(esp_http_client_event_t *evt) {
    resp_accum_t *acc = (resp_accum_t *)evt->user_data;

    switch (evt->event_id) {
    case HTTP_EVENT_ON_DATA:
        if (acc && evt->data && evt->data_len > 0) {
            if (acc->len + evt->data_len + 1 > acc->cap) {
                int newcap = acc->cap ? acc->cap : 2048;
                while (newcap < acc->len + evt->data_len + 1) newcap *= 2;
                char *nb = realloc(acc->buf, newcap);
                if (!nb) return ESP_FAIL;
                acc->buf = nb;
                acc->cap = newcap;
            }
            memcpy(acc->buf + acc->len, evt->data, evt->data_len);
            acc->len += evt->data_len;
            acc->buf[acc->len] = 0;
        }
        break;
    default:
        break;
    }
    return ESP_OK;
}

static esp_err_t http_request(const char *method,
                             const char *url,
                             const char *content_type,
                             const char *body,
                             int *out_status,
                             char **out_resp)
{
    if (out_resp) *out_resp = NULL;
    if (out_status) *out_status = -1;

    resp_accum_t acc = {0};

    esp_http_client_config_t cfg = {
        .url = url,
        .method = HTTP_METHOD_GET,
        .timeout_ms = 15000,
        .crt_bundle_attach = esp_crt_bundle_attach,
        .event_handler = http_event_handler,
        .user_data = &acc,
        .buffer_size = 8192,
        .buffer_size_tx = 4096,
    };

    if      (strcmp(method, "GET")   == 0) cfg.method = HTTP_METHOD_GET;
    else if (strcmp(method, "POST")  == 0) cfg.method = HTTP_METHOD_POST;
    else if (strcmp(method, "PUT")   == 0) cfg.method = HTTP_METHOD_PUT;
    else if (strcmp(method, "PATCH") == 0) cfg.method = HTTP_METHOD_PATCH;
    else return ESP_ERR_INVALID_ARG;

    esp_http_client_handle_t client = esp_http_client_init(&cfg);
    if (!client) return ESP_FAIL;

    if (content_type) esp_http_client_set_header(client, "Content-Type", content_type);
    esp_http_client_set_header(client, "Accept", "application/json");

    if (body) esp_http_client_set_post_field(client, body, (int)strlen(body));

    esp_err_t err = esp_http_client_perform(client);
    int status = (err == ESP_OK) ? esp_http_client_get_status_code(client) : -1;

    if (out_status) *out_status = status;

    if (err == ESP_OK && out_resp) {
        if (acc.buf) {
            *out_resp = acc.buf;
            acc.buf = NULL;
        } else {
            *out_resp = strdup("");
        }
    }

    esp_http_client_cleanup(client);
    if (acc.buf) free(acc.buf);

    return err;
}

// ===================== FIREBASE AUTH (EMAIL/PASS -> ID TOKEN) =====================

static esp_err_t firebase_sign_in_email_password(void) {
    ESP_LOGI(TAG, "Signing in (email/password)...");

    char url[256];
    snprintf(url, sizeof(url),
             "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=%s",
             FB_API_KEY);

    char post_body[512];
    snprintf(post_body, sizeof(post_body),
             "{\"email\":\"%s\",\"password\":\"%s\",\"returnSecureToken\":true}",
             FB_EMAIL, FB_PASSWORD);

    int status = -1;
    char *resp = NULL;
    esp_err_t err = http_request("POST", url, "application/json", post_body, &status, &resp);

    if (err != ESP_OK) {
        ESP_LOGW(TAG, "Signin HTTP failed: %s", esp_err_to_name(err));
        if (resp) free(resp);
        return err;
    }

    if (status < 200 || status >= 300) {
        ESP_LOGW(TAG, "Signin failed HTTP %d resp=%s", status, resp ? resp : "(null)");
        if (resp) free(resp);
        return ESP_FAIL;
    }

    cJSON *root = cJSON_Parse(resp ? resp : "");
    if (!root) {
        ESP_LOGW(TAG, "Signin JSON parse failed. Raw=%s", resp ? resp : "(null)");
        if (resp) free(resp);
        return ESP_FAIL;
    }

    cJSON *errObj = cJSON_GetObjectItem(root, "error");
    if (errObj) {
        cJSON *msg = cJSON_GetObjectItem(errObj, "message");
        ESP_LOGW(TAG, "Firebase signin error: %s", (msg && cJSON_IsString(msg)) ? msg->valuestring : "(unknown)");
        cJSON_Delete(root);
        if (resp) free(resp);
        return ESP_FAIL;
    }

    cJSON *idToken = cJSON_GetObjectItem(root, "idToken");
    cJSON *refreshToken = cJSON_GetObjectItem(root, "refreshToken");
    cJSON *localId = cJSON_GetObjectItem(root, "localId");

    if (!idToken || !cJSON_IsString(idToken) || !idToken->valuestring) {
        ESP_LOGW(TAG, "Signin resp missing idToken. Raw=%s", resp ? resp : "(null)");
        cJSON_Delete(root);
        if (resp) free(resp);
        return ESP_FAIL;
    }

    safe_strncpy(g_id_token, idToken->valuestring, sizeof(g_id_token));
    if (refreshToken && cJSON_IsString(refreshToken)) safe_strncpy(g_refresh_token, refreshToken->valuestring, sizeof(g_refresh_token));
    if (localId && cJSON_IsString(localId)) safe_strncpy(g_local_id, localId->valuestring, sizeof(g_local_id));

    ESP_LOGI(TAG, "Signin OK. localId=%s", g_local_id);

    cJSON_Delete(root);
    if (resp) free(resp);
    return ESP_OK;
}

// ===================== RTDB URL HELPERS =====================

static char *rtdb_url_build(const char *path_json) {
    size_t need = strlen(FB_RTDB_BASE) + strlen("/solar_data/users/") + strlen(FB_UID) +
                  strlen(path_json) + strlen("?auth=") + strlen(g_id_token) + 8;
    char *url = malloc(need);
    if (!url) return NULL;

    snprintf(url, need, "%s/solar_data/users/%s%s?auth=%s",
             FB_RTDB_BASE, FB_UID, path_json, g_id_token);
    return url;
}

static bool rtdb_status_is_auth_problem(int status, const char *resp) {
    if (status == 401 || status == 403) return true;
    if (resp && strstr(resp, "Permission denied")) return true;
    return false;
}

static esp_err_t rtdb_get(const char *path_json, char **out_resp) {
    char *url = rtdb_url_build(path_json);
    if (!url) return ESP_ERR_NO_MEM;

    int status = -1;
    esp_err_t err = http_request("GET", url, NULL, NULL, &status, out_resp);
    free(url);

    if (err == ESP_OK && status >= 200 && status < 300) return ESP_OK;

    if (rtdb_status_is_auth_problem(status, out_resp ? *out_resp : NULL)) {
        ESP_LOGW(TAG, "RTDB GET auth failed, refreshing token...");
        if (out_resp && *out_resp) { free(*out_resp); *out_resp = NULL; }

        if (firebase_sign_in_email_password() == ESP_OK) {
            url = rtdb_url_build(path_json);
            if (!url) return ESP_ERR_NO_MEM;
            status = -1;
            err = http_request("GET", url, NULL, NULL, &status, out_resp);
            free(url);
            if (err == ESP_OK && status >= 200 && status < 300) return ESP_OK;
        }
    }

    ESP_LOGW(TAG, "RTDB GET failed err=%s status=%d resp=%s",
             esp_err_to_name(err), status, (out_resp && *out_resp) ? *out_resp : "(null)");
    return ESP_FAIL;
}

static esp_err_t rtdb_patch(const char *path_json, const char *json_body) {
    char *url = rtdb_url_build(path_json);
    if (!url) return ESP_ERR_NO_MEM;

    char *resp = NULL;
    int status = -1;
    esp_err_t err = http_request("PATCH", url, "application/json", json_body, &status, &resp);
    free(url);
    if (resp) free(resp);

    if (err == ESP_OK && status >= 200 && status < 300) return ESP_OK;

    if (rtdb_status_is_auth_problem(status, NULL)) {
        ESP_LOGW(TAG, "RTDB PATCH auth failed, refreshing token...");
        if (firebase_sign_in_email_password() == ESP_OK) {
            url = rtdb_url_build(path_json);
            if (!url) return ESP_ERR_NO_MEM;
            status = -1;
            resp = NULL;
            err = http_request("PATCH", url, "application/json", json_body, &status, &resp);
            free(url);
            if (resp) free(resp);
            if (err == ESP_OK && status >= 200 && status < 300) return ESP_OK;
        }
    }

    ESP_LOGW(TAG, "RTDB PATCH failed err=%s status=%d", esp_err_to_name(err), status);
    return ESP_FAIL;
}

// ===================== I2C + OPT3001 =====================

static void i2c_init_old_driver(void) {
    i2c_config_t conf = {0};
    conf.mode = I2C_MODE_MASTER;
    conf.sda_io_num = GPIO_I2C_SDA;
    conf.scl_io_num = GPIO_I2C_SCL;
    conf.sda_pullup_en = GPIO_PULLUP_ENABLE;
    conf.scl_pullup_en = GPIO_PULLUP_ENABLE;
    conf.master.clk_speed = I2C_FREQ_HZ;

    ESP_ERROR_CHECK(i2c_param_config(I2C_PORT, &conf));
    ESP_ERROR_CHECK(i2c_driver_install(I2C_PORT, conf.mode, 0, 0, 0));
}

static void i2c_scan_bus(void) {
    ESP_LOGI(TAG, "I2C scan start...");
    int found = 0;

    for (int addr = 1; addr < 127; addr++) {
        i2c_cmd_handle_t cmd = i2c_cmd_link_create();
        i2c_master_start(cmd);
        i2c_master_write_byte(cmd, (addr << 1) | I2C_MASTER_WRITE, true);
        i2c_master_stop(cmd);
        esp_err_t err = i2c_master_cmd_begin(I2C_PORT, cmd, pdMS_TO_TICKS(40));
        i2c_cmd_link_delete(cmd);

        if (err == ESP_OK) {
            ESP_LOGI(TAG, "I2C device found at 0x%02X", addr);
            found++;
        }
    }

    if (!found) ESP_LOGW(TAG, "I2C scan found nothing.");
    ESP_LOGI(TAG, "I2C scan done.");
}

static esp_err_t i2c_write16(int addr, uint8_t reg, uint16_t val) {
    uint8_t data[3];
    data[0] = reg;
    data[1] = (uint8_t)((val >> 8) & 0xFF);
    data[2] = (uint8_t)(val & 0xFF);

    i2c_cmd_handle_t cmd = i2c_cmd_link_create();
    i2c_master_start(cmd);
    i2c_master_write_byte(cmd, (addr << 1) | I2C_MASTER_WRITE, true);
    i2c_master_write(cmd, data, sizeof(data), true);
    i2c_master_stop(cmd);

    esp_err_t err = i2c_master_cmd_begin(I2C_PORT, cmd, pdMS_TO_TICKS(200));
    i2c_cmd_link_delete(cmd);
    return err;
}

static esp_err_t i2c_read16(int addr, uint8_t reg, uint16_t *out) {
    if (!out) return ESP_ERR_INVALID_ARG;

    uint8_t hi = 0, lo = 0;

    i2c_cmd_handle_t cmd = i2c_cmd_link_create();
    i2c_master_start(cmd);
    i2c_master_write_byte(cmd, (addr << 1) | I2C_MASTER_WRITE, true);
    i2c_master_write_byte(cmd, reg, true);

    i2c_master_start(cmd);
    i2c_master_write_byte(cmd, (addr << 1) | I2C_MASTER_READ, true);
    i2c_master_read_byte(cmd, &hi, I2C_MASTER_ACK);
    i2c_master_read_byte(cmd, &lo, I2C_MASTER_NACK);
    i2c_master_stop(cmd);

    esp_err_t err = i2c_master_cmd_begin(I2C_PORT, cmd, pdMS_TO_TICKS(200));
    i2c_cmd_link_delete(cmd);

    if (err == ESP_OK) *out = ((uint16_t)hi << 8) | lo;
    return err;
}

static void opt3001_select_address(void) {
    gpio_config_t io = {0};
    io.intr_type = GPIO_INTR_DISABLE;
    io.mode = GPIO_MODE_OUTPUT;
    io.pin_bit_mask = 1ULL << GPIO_OPT_ADR;
    gpio_config(&io);

    gpio_set_level(GPIO_OPT_ADR, OPT_ADR_LEVEL ? 1 : 0);
    vTaskDelay(pdMS_TO_TICKS(10));

    g_opt_addr = OPT_ADR_LEVEL ? OPT3001_ADDR1 : OPT3001_ADDR0;
    ESP_LOGI(TAG, "OPT3001 ADR=%d -> addr=0x%02X", OPT_ADR_LEVEL, g_opt_addr);
}

static esp_err_t opt3001_init(void) {
    esp_err_t err = i2c_write16(g_opt_addr, OPT3001_REG_CONFIG, 0xC610);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "OPT3001 config write failed: %s (addr=0x%02X)", esp_err_to_name(err), g_opt_addr);
        return err;
    }
    vTaskDelay(pdMS_TO_TICKS(20));
    ESP_LOGI(TAG, "OPT3001 init OK");
    return ESP_OK;
}

static float opt3001_read_lux(void) {
    uint16_t raw = 0;
    if (i2c_read16(g_opt_addr, OPT3001_REG_RESULT, &raw) != ESP_OK) return NAN;

    uint16_t exp = (raw >> 12) & 0x0F;
    uint16_t mant = raw & 0x0FFF;

    float lux = (float)mant * 0.01f * (float)(1 << exp);
    return lux;
}

// ===================== GPIO INIT =====================

static void gpio_init_all(void) {
    gpio_config_t out = {0};
    out.intr_type = GPIO_INTR_DISABLE;
    out.mode = GPIO_MODE_OUTPUT;
    out.pull_down_en = 0;
    out.pull_up_en = 0;
    out.pin_bit_mask =
        (1ULL << GPIO_LIGHT1) |
        (1ULL << GPIO_LIGHT2) |
        (1ULL << GPIO_LIGHT3) |
        (1ULL << GPIO_LIGHT4);
    ESP_ERROR_CHECK(gpio_config(&out));

    gpio_set_level(GPIO_LIGHT1, 0);
    gpio_set_level(GPIO_LIGHT2, 0);
    gpio_set_level(GPIO_LIGHT3, 0);
    gpio_set_level(GPIO_LIGHT4, 0);

    gpio_config_t in = {0};
    in.intr_type = GPIO_INTR_DISABLE;
    in.mode = GPIO_MODE_INPUT;
    in.pull_down_en = 0;
    in.pull_up_en = 0;
    in.pin_bit_mask = (1ULL << GPIO_PIR_OUT);
    ESP_ERROR_CHECK(gpio_config(&in));
}

// ===================== LIGHT CONTROL =====================

static int json_get_boolish(const cJSON *obj, const char *key, int def_val) {
    const cJSON *it = cJSON_GetObjectItemCaseSensitive((cJSON*)obj, key);
    if (!it) return def_val;

    if (cJSON_IsBool(it)) return cJSON_IsTrue(it) ? 1 : 0;
    if (cJSON_IsNumber(it)) return (it->valuedouble != 0.0) ? 1 : 0;
    if (cJSON_IsString(it) && it->valuestring) {
        if (!strcasecmp(it->valuestring, "true")) return 1;
        if (!strcasecmp(it->valuestring, "false")) return 0;
        return (atoi(it->valuestring) != 0) ? 1 : 0;
    }
    return def_val;
}

// Parse lightingControls JSON and store values into shared state.
// task_auto_gpio reads these to drive GPIO. This function never touches GPIO or HTTP.
static void update_fb_lights_from_json(const char *json) {
    if (!json) return;

    cJSON *root = cJSON_Parse(json);
    if (!root || !cJSON_IsObject(root)) {
        ESP_LOGW(TAG, "lightingControls JSON parse failed. Raw=%s", json);
        if (root) cJSON_Delete(root);
        return;
    }

    int l1 = json_get_boolish(root, "light1", -1);
    int l2 = json_get_boolish(root, "light2", -1);
    int l3 = json_get_boolish(root, "light3", -1);
    int l4 = json_get_boolish(root, "light4", -1);

    if (l1 < 0) l1 = json_get_boolish(root, "Light1", -1);
    if (l2 < 0) l2 = json_get_boolish(root, "Light2", -1);
    if (l3 < 0) l3 = json_get_boolish(root, "Light3", -1);
    if (l4 < 0) l4 = json_get_boolish(root, "Light4", -1);

    cJSON_Delete(root);

    xSemaphoreTake(g_state_mutex, portMAX_DELAY);
    if (l1 >= 0) g_fb_light1 = l1;
    if (l2 >= 0) g_fb_light2 = l2;
    if (l3 >= 0) g_fb_light3 = l3;
    if (l4 >= 0) g_fb_light4 = l4;
    xSemaphoreGive(g_state_mutex);

    ESP_LOGD(TAG, "FB lights: L1=%d L2=%d L3=%d L4=%d", l1, l2, l3, l4);
}

// ===================== SENSOR TASK =====================
// Priority 7. ONLY reads GPIO and I2C — zero HTTP ever.
// Updates shared state; signals task_firebase via queues on change.
//
// Motion hold logic:
//   g_motion goes TRUE the instant PIR goes HIGH.
//   The countdown starts when PIR goes LOW and STAYS low.
//   If PIR fires again while counting down, the countdown resets.
//   g_motion goes FALSE only after PIR has been continuously LOW for MOTION_HOLD_MS.
//   This means frequent re-triggers (person still present) keep g_motion TRUE,
//   and it only drops to FALSE once the area has truly been quiet for the hold window.

static void task_sensors(void *arg) {
    (void)arg;

    int        last_motion_reported = -1;
    bool       motion_held          = false;
    bool       pir_prev             = false;      // PIR state last sample
    TickType_t pir_went_low_tick    = 0;          // tick when PIR last fell LOW

    while (1) {
        TickType_t now     = xTaskGetTickCount();
        int        pir_raw = gpio_get_level(GPIO_PIR_OUT) ? 1 : 0;

        if (pir_raw) {
            // PIR is HIGH — assert motion, cancel any pending countdown
            motion_held       = true;
            pir_went_low_tick = 0;    // reset: not counting down while PIR is active
        } else {
            if (pir_prev) {
                // Falling edge: PIR just went LOW — start countdown from now
                pir_went_low_tick = now;
            }
            // PIR is LOW: expire hold only after it has stayed low for the full window
            if (motion_held && pir_went_low_tick > 0 &&
                (now - pir_went_low_tick) >= pdMS_TO_TICKS(MOTION_HOLD_MS)) {
                motion_held       = false;
                pir_went_low_tick = 0;
            }
        }
        pir_prev = (bool)pir_raw;

        int motion = motion_held ? 1 : 0;

        // ---- Lux ----
        float lux      = opt3001_read_lux();
        int   is_night = (!isnan(lux) && lux < 10.0f) ? 1 : 0;

        // ---- Update shared state (µs — mutex + assignment only) ----
        xSemaphoreTake(g_state_mutex, portMAX_DELAY);
        g_motion   = motion;
        g_is_night = is_night;
        if (!isnan(lux)) g_lux = lux;
        xSemaphoreGive(g_state_mutex);

        // ---- Signal task_firebase on motion change (non-blocking) ----
        if (motion != last_motion_reported) {
            char body[MOTION_FB_BODY_LEN];
            snprintf(body, sizeof(body),
                     "{\"motion\":%s,\"isNight\":%s}",
                     motion   ? "true" : "false",
                     is_night ? "true" : "false");
            xQueueOverwrite(g_motion_fb_queue, body);
            ESP_LOGI(TAG, "Motion->%d (raw=%d countdown=%lu ms)",
                     motion, pir_raw,
                     pir_went_low_tick ? (unsigned long)(now - pir_went_low_tick) : 0UL);
            last_motion_reported = motion;
        }

        vTaskDelay(pdMS_TO_TICKS(MOTION_POLL_MS));
    }
}

// ===================== AUTO GPIO TASK =====================
// Priority 6. Runs every 20ms. Pure shared-RAM reads → GPIO writes. Zero HTTP.
//
// Inside lights (L1/L2): always follow g_fb_light1/2 (polled from Firebase by task_firebase).
//
// Outside lights (L3/L4) — all modes support manual override:
//   Mode 0:      always follow Firebase (fully manual).
//   Modes 1/2/3: trigger computed locally from shared state.
//                - Trigger ON  (rising edge): force GPIO=1, write Firebase=true.
//                - Trigger OFF (falling edge): force GPIO=0, write Firebase=false,
//                  then clear g_fb_light3/4 so manual starts from a clean OFF state.
//                - Trigger steady-state: follow Firebase — manual changes in the app
//                  take effect immediately on GPIO with no board write needed.
//
// This means: when trigger is inactive, the user can freely toggle L3/L4 in the app
// and the board reflects it within one Firebase poll cycle. When trigger fires, auto
// wins; when trigger ends, board writes false once then hands control back to the app.

static void task_auto_gpio(void *arg) {
    (void)arg;

    int  last_pref    = -1;
    bool prev_trigger = false; // tracks trigger state across loop iterations

    while (1) {
        // Snapshot all shared state in one critical section
        int  pref, motion, is_night, auto_l3, auto_l4;
        int  fb_l1, fb_l2, fb_l3, fb_l4;
        bool human;
        xSemaphoreTake(g_state_mutex, portMAX_DELAY);
        pref     = g_night_light_pref;
        motion   = g_motion;
        is_night = g_is_night;
        human    = g_human_detected;
        auto_l3  = g_auto_light3;
        auto_l4  = g_auto_light4;
        fb_l1    = g_fb_light1;
        fb_l2    = g_fb_light2;
        fb_l3    = g_fb_light3;
        fb_l4    = g_fb_light4;
        xSemaphoreGive(g_state_mutex);

        // ---- Mode transition handling ----
        if (pref != last_pref) {
            ESP_LOGI(TAG, "Mode transition: %d -> %d", last_pref, pref);

            if (pref == 0 && last_pref > 0) {
                // Auto → mode 0: force outside lights OFF, write Firebase, clear cache
                gpio_set_level(GPIO_LIGHT3, 0);
                gpio_set_level(GPIO_LIGHT4, 0);
                xSemaphoreTake(g_state_mutex, portMAX_DELAY);
                g_auto_light3 = 0; g_auto_light4 = 0;
                g_fb_light3   = 0; g_fb_light4   = 0;
                xSemaphoreGive(g_state_mutex);
                lights_fb_msg_t msg = {0, 0};
                xQueueOverwrite(g_lights_fb_queue, &msg);
                fb_l3 = 0; fb_l4 = 0;
                auto_l3 = 0; auto_l4 = 0;
            }

            if (pref != 0) {
                // → auto mode: reset auto tracking, clear stale human flag for mode 1
                xSemaphoreTake(g_state_mutex, portMAX_DELAY);
                g_auto_light3 = -1;
                g_auto_light4 = -1;
                if (pref == 1) g_human_detected = false;
                xSemaphoreGive(g_state_mutex);
                auto_l3 = -1;
                auto_l4 = -1;
            }

            // Reset trigger edge tracking on every mode change
            prev_trigger = false;
            last_pref = pref;
        }

        // ---- Inside lights (L1/L2): always follow Firebase ----
        if (fb_l1 >= 0) gpio_set_level(GPIO_LIGHT1, fb_l1);
        if (fb_l2 >= 0) gpio_set_level(GPIO_LIGHT2, fb_l2);

        // ---- Outside lights (L3/L4) ----
        bool trigger = false;
        int  new_l3, new_l4;
        bool write_fb = false;

        if (pref == 0) {
            // Mode 0: fully manual — follow Firebase, no board writes
            new_l3 = (fb_l3 >= 0) ? fb_l3 : gpio_get_level(GPIO_LIGHT3);
            new_l4 = (fb_l4 >= 0) ? fb_l4 : gpio_get_level(GPIO_LIGHT4);

        } else {
            // Auto modes: compute trigger
            // Mode 1: motion AND lux < 10
            // Mode 2: human AND lux < 10
            // Mode 3: motion AND human AND lux < 10
            // Mode 4: lux < 10 (always on when dark)
            if      (pref == 1) trigger = (bool)(motion && is_night);
            else if (pref == 2) trigger = (bool)(human  && is_night);
            else if (pref == 3) trigger = (bool)(motion && human && is_night);
            else                trigger = (bool)(is_night); // mode 4

            bool rising_edge  = ( trigger && !prev_trigger);
            bool falling_edge = (!trigger &&  prev_trigger);
            // Also handle first run after mode switch (auto_l3 == -1)
            bool first_run    = (auto_l3 < 0);

            if (trigger) {
                // Trigger active: auto ON
                new_l3 = 1;
                new_l4 = 1;
                if (rising_edge || first_run) {
                    write_fb = true; // write true to Firebase once on rising edge
                }
            } else {
                if (falling_edge || first_run) {
                    // Trigger just ended: force OFF, write Firebase=false,
                    // clear cache so app can manually override cleanly after this
                    new_l3 = 0;
                    new_l4 = 0;
                    write_fb = true;
                    // Clear fb cache immediately so next loop follows fresh manual state
                    xSemaphoreTake(g_state_mutex, portMAX_DELAY);
                    g_fb_light3 = 0;
                    g_fb_light4 = 0;
                    xSemaphoreGive(g_state_mutex);
                    fb_l3 = 0; fb_l4 = 0;
                } else {
                    // Trigger steady-state OFF: follow Firebase (manual override works here)
                    new_l3 = (fb_l3 >= 0) ? fb_l3 : gpio_get_level(GPIO_LIGHT3);
                    new_l4 = (fb_l4 >= 0) ? fb_l4 : gpio_get_level(GPIO_LIGHT4);
                }
            }
        }

        // Set GPIO immediately
        gpio_set_level(GPIO_LIGHT3, new_l3);
        gpio_set_level(GPIO_LIGHT4, new_l4);

        // Queue Firebase write if needed, update local tracking
        if (write_fb) {
            xSemaphoreTake(g_state_mutex, portMAX_DELAY);
            g_auto_light3 = new_l3;
            g_auto_light4 = new_l4;
            g_fb_light3   = new_l3; // keep cache in sync with what we're writing
            g_fb_light4   = new_l4;
            xSemaphoreGive(g_state_mutex);
            lights_fb_msg_t msg = { new_l3, new_l4 };
            xQueueOverwrite(g_lights_fb_queue, &msg);
            ESP_LOGI(TAG, "Outside FB write: L3=%d L4=%d (mode=%d trigger=%d->%d)",
                     new_l3, new_l4, pref, (int)prev_trigger, (int)trigger);
        } else if (pref != 0) {
            // In auto mode, keep g_auto tracking in sync with current GPIO state
            // so mode transitions and first_run logic stay accurate
            if (new_l3 != auto_l3 || new_l4 != auto_l4) {
                xSemaphoreTake(g_state_mutex, portMAX_DELAY);
                g_auto_light3 = new_l3;
                g_auto_light4 = new_l4;
                xSemaphoreGive(g_state_mutex);
            }
        }

        prev_trigger = trigger;
        vTaskDelay(pdMS_TO_TICKS(20));
    }
}

// ===================== FIREBASE TASK =====================
// Priority 5. Handles ALL HTTP — never blocks GPIO or sensor tasks.
//
// Writes:
//   - Motion state changes (from g_motion_fb_queue, depth-1 overwrite queue)
//   - Outside light state changes (from g_lights_fb_queue, depth-1 overwrite queue)
//   - Lux every LUX_UPLOAD_INTERVAL_MS (reads from shared state)
//
// Reads (results stored in shared state for task_auto_gpio to consume):
//   - lightingControls every LIGHTS_POLL_MS  → g_fb_light1..4
//   - settings/nightLightPref every SETTINGS_POLL_MS → g_night_light_pref
//   - humanActivity/detected every HUMAN_POLL_MS (modes 2/3 only) → g_human_detected

static void task_firebase(void *arg) {
    (void)arg;

    TickType_t last_lux_tick      = xTaskGetTickCount() - pdMS_TO_TICKS(LUX_UPLOAD_INTERVAL_MS);
    TickType_t last_lights_tick   = 0;
    TickType_t last_settings_tick = 0;
    TickType_t last_human_tick    = 0;

    while (1) {
        TickType_t now = xTaskGetTickCount();

        // ---- Drain motion write queue (non-blocking check) ----
        {
            char body[MOTION_FB_BODY_LEN];
            if (xQueueReceive(g_motion_fb_queue, body, 0) == pdTRUE) {
                esp_err_t r = rtdb_patch("/sensorData.json", body);
                ESP_LOGI(TAG, "Motion FB: %s [%s]", body, r == ESP_OK ? "OK" : "FAIL");
            }
        }

        // ---- Drain lights write queue (non-blocking check) ----
        {
            lights_fb_msg_t msg;
            if (xQueueReceive(g_lights_fb_queue, &msg, 0) == pdTRUE) {
                char body[96];
                snprintf(body, sizeof(body),
                         "{\"light3\":%s,\"light4\":%s}",
                         msg.l3 ? "true" : "false",
                         msg.l4 ? "true" : "false");
                esp_err_t r = rtdb_patch("/lightingControls.json", body);
                ESP_LOGI(TAG, "Lights FB: L3=%d L4=%d [%s]", msg.l3, msg.l4,
                         r == ESP_OK ? "OK" : "FAIL");
            }
        }

        // ---- Lux upload (30-second cadence) ----
        if ((now - last_lux_tick) >= pdMS_TO_TICKS(LUX_UPLOAD_INTERVAL_MS)) {
            float lux;
            int   is_night;
            xSemaphoreTake(g_state_mutex, portMAX_DELAY);
            lux      = g_lux;
            is_night = g_is_night;
            xSemaphoreGive(g_state_mutex);

            if (!isnan(lux)) {
                char body[MOTION_FB_BODY_LEN];
                snprintf(body, sizeof(body),
                         "{\"lux\":%.2f,\"isNight\":%s}",
                         lux, is_night ? "true" : "false");
                rtdb_patch("/sensorData.json", body);
                ESP_LOGI(TAG, "Lux FB: %.2f isNight=%d", lux, is_night);
            }
            last_lux_tick = now;
        }

        // ---- lightingControls read (for inside lights + mode 0 outside) ----
        if ((now - last_lights_tick) >= pdMS_TO_TICKS(LIGHTS_POLL_MS)) {
            last_lights_tick = now;
            char *resp = NULL;
            if (rtdb_get("/lightingControls.json", &resp) == ESP_OK && resp) {
                update_fb_lights_from_json(resp);
            }
            if (resp) free(resp);
        }

        // ---- Settings read ----
        if ((now - last_settings_tick) >= pdMS_TO_TICKS(SETTINGS_POLL_MS)) {
            last_settings_tick = now;
            char *resp = NULL;
            if (rtdb_get("/settings/nightLightPref.json", &resp) == ESP_OK && resp) {
                int pref = atoi(resp);
                if (pref < 0) pref = 0;
                if (pref > 4) pref = 4;
                xSemaphoreTake(g_state_mutex, portMAX_DELAY);
                g_night_light_pref = pref;
                xSemaphoreGive(g_state_mutex);
                ESP_LOGD(TAG, "nightLightPref=%d", pref);
            }
            if (resp) free(resp);
        }

        // ---- humanActivity read (only needed for modes 2 and 3) ----
        int cur_pref;
        xSemaphoreTake(g_state_mutex, portMAX_DELAY);
        cur_pref = g_night_light_pref;
        xSemaphoreGive(g_state_mutex);

        if ((cur_pref == 2 || cur_pref == 3) &&
            (now - last_human_tick) >= pdMS_TO_TICKS(HUMAN_POLL_MS)) {
            last_human_tick = now;
            char *resp = NULL;
            if (rtdb_get("/sensorData/humanActivity/detected.json", &resp) == ESP_OK && resp) {
                bool detected = (strcmp(resp, "true") == 0 || strcmp(resp, "1") == 0);
                xSemaphoreTake(g_state_mutex, portMAX_DELAY);
                g_human_detected = detected;
                xSemaphoreGive(g_state_mutex);
                ESP_LOGD(TAG, "humanDetected=%d", (int)detected);
            }
            if (resp) free(resp);
        }

        // Short sleep — all rate-limiting is done with tick timers above
        vTaskDelay(pdMS_TO_TICKS(50));
    }
}

// ===================== CONNECT OR FALLBACK =====================

static void enter_setup_mode_forever(void) {
    ESP_ERROR_CHECK(wifi_start_setup_ap());
    http_server_start();
    while (1) vTaskDelay(pdMS_TO_TICKS(1000));
}

static void connect_sta_or_fallback(void) {
    if (nvs_load_wifi_creds() != ESP_OK || strlen(g_wifi_ssid) == 0) {
        enter_setup_mode_forever();
    }

    ESP_LOGI(TAG, "Wi-Fi creds found SSID='%s', connecting...", g_wifi_ssid);

    ESP_ERROR_CHECK(wifi_start_sta_only());

    int tries = 0;
    while (tries < WIFI_CONNECT_MAX_TRIES) {
        if (wifi_wait_connected_ms(8000)) {
            ESP_LOGI(TAG, "Wi-Fi connected.");
            set_dns_8888();
            return;
        }
        tries++;
        ESP_LOGW(TAG, "Wi-Fi not connected yet (%d/%d)", tries, WIFI_CONNECT_MAX_TRIES);
        esp_wifi_disconnect();
        vTaskDelay(pdMS_TO_TICKS(600));
        esp_wifi_connect();
    }

    ESP_LOGW(TAG, "Wi-Fi failed after %d tries -> clearing creds and reboot to setup", WIFI_CONNECT_MAX_TRIES);
    nvs_clear_wifi_creds();
    vTaskDelay(pdMS_TO_TICKS(300));
    esp_restart();
}

// ===================== APP MAIN =====================

void app_main(void) {
    ESP_ERROR_CHECK(nvs_flash_init());

    gpio_init_all();

    // Create shared-state mutex and both queues before tasks start
    g_state_mutex     = xSemaphoreCreateMutex();
    g_motion_fb_queue = xQueueCreate(MOTION_FB_QUEUE_DEPTH, MOTION_FB_BODY_LEN);
    g_lights_fb_queue = xQueueCreate(1, sizeof(lights_fb_msg_t));
    configASSERT(g_state_mutex);
    configASSERT(g_motion_fb_queue);
    configASSERT(g_lights_fb_queue);

    // Wi-Fi: either connect STA or enter AP+setup page
    connect_sta_or_fallback();

    ESP_LOGI(TAG, "System ready");

    sntp_time_sync();

    // I2C + sensors init
    i2c_init_old_driver();
    opt3001_select_address();
    i2c_scan_bus();
    ESP_ERROR_CHECK(opt3001_init());

    // Firebase sign-in
    if (firebase_sign_in_email_password() != ESP_OK) {
        ESP_LOGW(TAG, "Signin failed; entering setup mode instead of aborting.");
        enter_setup_mode_forever();
        return;
    }

    // task_sensors  (7): PIR + lux reads only — zero HTTP, zero GPIO writes
    // task_auto_gpio(6): GPIO control from shared RAM — zero HTTP, true 20ms loop
    // task_firebase (5): ALL HTTP reads and writes — never touches GPIO
    xTaskCreate(task_sensors,   "task_sensors",   TASK_STACK_SENSORS,        NULL, 7, NULL);
    xTaskCreate(task_auto_gpio, "task_auto_gpio", TASK_STACK_LIGHTS,         NULL, 6, NULL);
    xTaskCreate(task_firebase,  "task_firebase",  TASK_STACK_SENSORS + 2048, NULL, 5, NULL);
}