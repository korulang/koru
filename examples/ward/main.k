// Ward — Koru contract. Host sysinfo lives in the companion `main.kz`.
// Same routes as ward-rs: GET /api/{info,usage,uptime}, POST /api/setup,
// static assets. GET / is the dashboard once setup.ini exists, else setup.

import orisha
import std/io
import std/fmt
import std/fs

pub tor usage {} -> { processor: i32, ram: i32, storage: i32 }

pub tor uptime {} -> { days: string, hours: string, minutes: string, seconds: string }

pub tor info {} -> {
    processor_name: string,
    processor_core_count: string,
    processor_clock_speed: string,
    processor_bit_depth: string,
    machine_operating_system: string,
    machine_total_ram: string,
    machine_ram_type_or_os_bit_depth: string,
    machine_proc_count: string,
    storage_main_storage: string,
    storage_total: string,
    storage_disk_count: string,
    storage_swap_amount: string,
}

pub tor parse-setup { body: ?string }
| ready string
| invalid

pub tor parse-ini { raw: string }
| cfg { server_name: string, theme: string, port: string, enable_fog: string, background_color: string }
| invalid

pub tor listen-port {} -> u16

orisha:static(name: "site", root: "public")

orisha:handler = orisha:router(req)
! [GET /api/usage] |> usage(): u |> std/fmt:ln("{\"processor\":{{ u.processor:d }},\"ram\":{{ u.ram:d }},\"storage\":{{ u.storage:d }}}"): l -> { status: 200, body: l.text, content_type: "application/json" }
! [GET /api/uptime] |> uptime(): u |> std/fmt:ln("{\"days\":\"{{ u.days:s }}\",\"hours\":\"{{ u.hours:s }}\",\"minutes\":\"{{ u.minutes:s }}\",\"seconds\":\"{{ u.seconds:s }}\"}"): l -> { status: 200, body: l.text, content_type: "application/json" }
! [GET /api/info] |> info(): i |> std/fmt:ln("{\"processor\":{\"name\":\"{{ i.processor_name:s }}\",\"coreCount\":\"{{ i.processor_core_count:s }}\",\"clockSpeed\":\"{{ i.processor_clock_speed:s }}\",\"bitDepth\":\"{{ i.processor_bit_depth:s }}\"},\"machine\":{\"operatingSystem\":\"{{ i.machine_operating_system:s }}\",\"totalRam\":\"{{ i.machine_total_ram:s }}\",\"ramTypeOrOSBitDepth\":\"{{ i.machine_ram_type_or_os_bit_depth:s }}\",\"procCount\":\"{{ i.machine_proc_count:s }}\"},\"storage\":{\"mainStorage\":\"{{ i.storage_main_storage:s }}\",\"total\":\"{{ i.storage_total:s }}\",\"diskCount\":\"{{ i.storage_disk_count:s }}\",\"swapAmount\":\"{{ i.storage_swap_amount:s }}\"}}"): l -> { status: 200, body: l.text, content_type: "application/json" }
! [POST /api/setup] |> parse-setup(req.body)
    | ready s |> std/fs:write(path: "setup.ini", content: s)
        | written -> { status: 200, body: "ok", content_type: "text/plain" }
        | failed e -> { status: 400, body: e, content_type: "text/plain" }
    | invalid -> { status: 400, body: "invalid", content_type: "text/plain" }
! [GET /] |> std/io:read-file(path: "setup.ini")
    | ok raw |> parse-ini(raw)
        | cfg c |> info(): i |> uptime(): u |> std/fmt:fmt.blk {
    <!DOCTYPE html>
    <html lang = "en" id = "html" theme = "{{ c.theme:s }}" enableFog = "{{ c.enable_fog:s }}" backgroundColor = "{{ c.background_color:s }}">
        <head>
            <meta charset = "UTF-8">
            <title>{{ c.server_name:s }}</title>
            <link rel = "shortcut icon" type = "image/x-icon" href="/img/ico/favicon.ico" />
            <link rel = "stylesheet" type = "text/css" href="/css/assets/bootstrap.min.css" />
            <link rel = "stylesheet" type = "text/css" href="/css/animations.css" />
            <link rel = "stylesheet" type = "text/css" href="/css/colors.css" />
            <link rel = "stylesheet" type = "text/css" href="/css/dimensions.css" />
            <link rel = "stylesheet" type = "text/css" href="/css/fonts.css" />
            <link rel = "stylesheet" type = "text/css" href="/css/gradients.css" />
            <link rel = "stylesheet" type = "text/css" href="/css/layout.css" />
            <link rel = "stylesheet" type = "text/css" href="/css/shadows.css" />
            <link rel = "stylesheet" type = "text/css" href="/css/themes.css" />
            <script type = "text/javascript" src="/js/assets/chart.min.js"></script>
            <script type = "text/javascript" src="/js/assets/three.min.js"></script>
            <script type = "text/javascript" src="/js/assets/vanta.min.js"></script>
            <script type = "text/javascript" src="/js/background.js"></script>
            <script type = "text/javascript" src="/js/chart.js"></script>
            <script type = "text/javascript" src="/js/globals.js"></script>
            <script type = "text/javascript" src="/js/index.js"></script>
            <script type = "text/javascript" src="/js/labels.js"></script>
            <script type = "text/javascript" > globalsInitialization(); </script>
        </head>
        <body id = "background">
            <script type = "text/javascript" > backgroundInitialization(); </script>
            <div class = "container index">
                <div class = "row">
                    <div class = "col-sm-12 col-md-6 col-lg-6 col-xl-4 px-3">
                        <div class = "card">
                            <div class = "header">
                                <div class = "hw-logo first">
                                    <img class = "hardware-icon" src="/img/icons/processor.png" />
                                </div>
                                <div class = "label-hw-info">
                                    <div class = "hw-type">Processor</div>
                                    <div class = "hw-name">{{ i.processor_name:s }}</div>
                                </div>
                            </div>
                            <div class = "usage">
                                <div class = "main-hw-info">
                                    <div class = "hw-usage">
                                        <div class = "usage-value">
                                            <span id = "processor-hundreds" class = "first">0</span>
                                            <span id = "processor-tens" class = "second">0</span>
                                            <span id = "processor-ones" class = "third">0</span>
                                        </div>
                                        <div class = "usage-postfix">%</div>
                                    </div>
                                    <p class = "info-label">PROCESSOR USAGE</p>
                                    <div class = "usage-underline first"></div>
                                </div>
                            </div>
                            <div class = "footer first">
                                <div class = "detailed-hw-info">
                                    <div class = "first">{{ i.processor_core_count:s }}</div>
                                    <div id = "currentClockSpeed" class = "second">{{ i.processor_clock_speed:s }}</div>
                                    <div class = "third">{{ i.processor_bit_depth:s }}</div>
                                </div>
                                <div class = "dividers">
                                    <div class = "first"></div>
                                    <div class = "second"></div>
                                </div>
                            </div>
                        </div>
                    </div>
                    <div class = "col-sm-12 col-md-6 col-lg-6 col-xl-4 px-3">
                        <div class = "card">
                            <div class = "header">
                                <div class = "hw-logo second">
                                    <img class = "hardware-icon" src="/img/icons/memory.png" />
                                </div>
                                <div class = "label-hw-info">
                                    <div class = "hw-type">Memory</div>
                                    <div class = "hw-name">{{ i.machine_operating_system:s }}</div>
                                </div>
                            </div>
                            <div class = "usage">
                                <div class = "main-hw-info">
                                    <div class = "hw-usage">
                                        <div class = "usage-value">
                                            <span id = "ram-hundreds" class = "first">0</span>
                                            <span id = "ram-tens" class = "second">0</span>
                                            <span id = "ram-ones" class = "third">0</span>
                                        </div>
                                        <div class = "usage-postfix">%</div>
                                    </div>
                                    <p class = "info-label">MEMORY USAGE</p>
                                    <div class = "usage-underline second"></div>
                                </div>
                            </div>
                            <div class = "footer second">
                                <div class = "detailed-hw-info">
                                    <div class = "first">{{ i.machine_total_ram:s }}</div>
                                    <div class = "second">{{ i.machine_ram_type_or_os_bit_depth:s }}</div>
                                    <div id = "currentProcCount" class = "third">{{ i.machine_proc_count:s }}</div>
                                </div>
                                <div class = "dividers">
                                    <div class = "first"></div>
                                    <div class = "second"></div>
                                </div>
                            </div>
                        </div>
                    </div>
                    <div class = "col-sm-12 col-md-6 col-lg-6 col-xl-4 px-3">
                        <div class = "card">
                            <div class = "header">
                                <div class = "hw-logo third">
                                    <img class = "hardware-icon" src="/img/icons/disk.png" />
                                </div>
                                <div class = "label-hw-info">
                                    <div class = "hw-type">Storage</div>
                                    <div class = "hw-name">{{ i.storage_main_storage:s }}</div>
                                </div>
                            </div>
                            <div class = "usage">
                                <div class = "main-hw-info">
                                    <div class = "hw-usage">
                                        <div class = "usage-value">
                                            <span id = "storage-hundreds" class = "first">0</span>
                                            <span id = "storage-tens" class = "second">0</span>
                                            <span id = "storage-ones" class = "third">0</span>
                                        </div>
                                        <div class = "usage-postfix">%</div>
                                    </div>
                                    <p class = "info-label">STORAGE USAGE</p>
                                    <div class = "usage-underline third"></div>
                                </div>
                            </div>
                            <div class = "footer third">
                                <div class = "detailed-hw-info">
                                    <div id = "currentTotalStorage" class = "first">{{ i.storage_total:s }}</div>
                                    <div id = "currentDiskCount" class = "second">{{ i.storage_disk_count:s }}</div>
                                    <div class = "third">{{ i.storage_swap_amount:s }}</div>
                                </div>
                                <div class = "dividers">
                                    <div class = "first"></div>
                                    <div class = "second"></div>
                                </div>
                            </div>
                        </div>
                    </div>
                    <script type = "text/javascript" > labelsInitialization(); </script>
                    <div class = "col-sm-12 col-md-6 col-lg-6 col-xl-4 px-3 sm-hidden">
                        <div class = "card">
                            <div class = "logo">WARD</div>
                            <div class = "logo-description">SERVER DASHBOARD</div>
                            <div class = "clouds">
                                <img id = "cloud-left" class = "first" src="/img/logo/clouds/left.png" />
                                <img id = "cloud-right" class = "second" src="/img/logo/clouds/right.png" />
                            </div>
                            <img class = "background" src="/img/logo/background.png" />
                            <div class = "uptime">
                                <div class = "uptime-rectangle-grid">
                                    <div class = "values-grid">
                                        <div><p id = "uptime-days">{{ u.days:s }}</p></div>
                                        <div><p id = "uptime-hours">{{ u.hours:s }}</p></div>
                                        <div><p id = "uptime-minutes">{{ u.minutes:s }}</p></div>
                                        <div><p id = "uptime-seconds">{{ u.seconds:s }}</p></div>
                                    </div>
                                    <div class = "labels-grid">
                                        <div>DAYS</div>
                                        <div>HOURS</div>
                                        <div>MINUTES</div>
                                        <div>SECONDS</div>
                                    </div>
                                </div>
                            </div>
                        </div>
                    </div>
                    <div class = "col-lg-12 col-xl-8 px-3 sm-hidden">
                        <div class = "card">
                            <div class = "chart-label">Hardware Utilization (%)</div>
                            <div class = "chart-triangle-grid">
                                <div id = "processor-triangle" class = "first"></div>
                                <div id = "ram-triangle" class = "second"></div>
                                <div id = "storage-triangle" class = "third"></div>
                            </div>
                            <div class = "chart-rectangle-grid">
                                <div id = "processor-rectangle" class = "first"></div>
                                <div id = "ram-rectangle" class = "second"></div>
                                <div id = "storage-rectangle" class = "third"></div>
                            </div>
                            <div class = "chart-container">
                                <canvas id = "chart-body"></canvas>
                            </div>
                            <script type = "text/javascript" > chartInitialization(); </script>
                        </div>
                        <div id = "project-version" class = "text-center">{{ c.server_name:s }}    0.1.0</div>
                    </div>
                </div>
            </div>
            <script type = "text/javascript" > indexInitialization(); </script>
        </body>
    </html>
          }: f -> { status: 200, body: f, content_type: "text/html" }
        | invalid -> { status: 500, body: "invalid setup.ini", content_type: "text/plain" }
    | not-found |> listen-port(): port |> std/fmt:fmt.blk {
    <!DOCTYPE html>
    <html id = "html" theme = "light" enableFog = "true" backgroundColor = "default">
        <head>
            <meta charset = "UTF-8">
            <title>Welcome</title>
            <link rel = "shortcut icon" type = "image/x-icon" href="/img/ico/favicon.ico" />
            <link rel = "stylesheet" type = "text/css" href="/css/assets/bootstrap.min.css" />
            <link rel = "stylesheet" type = "text/css" href="/css/animations.css" />
            <link rel = "stylesheet" type = "text/css" href="/css/colors.css" />
            <link rel = "stylesheet" type = "text/css" href="/css/dimensions.css" />
            <link rel = "stylesheet" type = "text/css" href="/css/fonts.css" />
            <link rel = "stylesheet" type = "text/css" href="/css/gradients.css" />
            <link rel = "stylesheet" type = "text/css" href="/css/layout.css" />
            <link rel = "stylesheet" type = "text/css" href="/css/shadows.css" />
            <link rel = "stylesheet" type = "text/css" href="/css/themes.css" />
            <script type = "text/javascript" src="/js/assets/sweetalert2.min.js"></script>
            <script type = "text/javascript" src="/js/assets/three.min.js"></script>
            <script type = "text/javascript" src="/js/assets/vanta.min.js"></script>
            <script type = "text/javascript" src="/js/background.js"></script>
            <script type = "text/javascript" src="/js/globals.js"></script>
            <script type = "text/javascript" src="/js/setup.js"></script>
            <script type = "text/javascript" > globalsInitialization(); </script>
            <script>
                document.addEventListener("DOMContentLoaded", function() {
                    var input = document.getElementById('port');
                    input.addEventListener('input', function() {
                        this.value = this.value.replace(/[^0-9]/g, '');
                        if (this.value.length > 5) {
                            this.value = this.value.slice(0, 5);
                        }
                    });
                });
            </script>
        </head>
        <body id = "background">
            <script type = "text/javascript" > backgroundInitialization(); </script>
            <div class = "container setup">
                <div class = "setup-div">
                    <div class = "logo">WARD</div>
                    <div class = "logo-description">SERVER DASHBOARD</div>
                    <div class = "clouds">
                        <img class = "first" src="/img/logo/clouds/left.png" />
                        <img class = "second" src="/img/logo/clouds/right.png" />
                    </div>
                    <img class = "background" src="/img/logo/background.png" />
                    <div class = "form">
                        <div class = "form-squares-grid">
                            <div class = "first"></div>
                            <div class = "second"></div>
                            <div class = "third"></div>
                        </div>
                        <div class = "label-main-settings">MAIN SETTINGS</div>
                        <div class = "main-settings">
                            <input id = "server-name" type = "text" maxlength = "10" placeholder = "Server Name" />
                            <div class = "main-settings-underline first"></div>
                        </div>
                        <div class = "label-additional-settings">ADDITIONAL SETTINGS</div>
                        <div class = "additional-settings">
                            <div class = "button-squares-grid">
                                <div id = "light-theme-square" class = "first"></div>
                                <div id = "dark-theme-square" class = "second"></div>
                            </div>
                            <div class = "theme-buttons">
                                <input id = "light-theme" class = "first" type = "button" value = "LIGHT THEME" />
                                <input id = "dark-theme" class = "second" type = "button" value = "DARK THEME" />
                            </div>
                            <label class = "label-additional-settings"><span>ENABLE BACKGROUND FOG</span><input id = "fog-toggle" class = "fog-toggle" type = "checkbox" name = "enableFog" checked></label>
                            <label class = "label-additional-settings" title="Disable Fog to select"><span>SELECT BACKGROUND COLOR</span><input id = "color-selector" class = "color-selector" type = "color" value="#e5e5e5" disabled></label>
                            <input id = "port" class = "port" type = "text" maxlength = "5" placeholder = "Application Port" value="{{ port:d }}" />
                        </div>
                        <input id = "submit" class = "submit" type = "button" value = "LAUNCH" />
                    </div>
                </div>
            </div>
            <script type = "text/javascript" > setupInitialization(); </script>
        </body>
    </html>
    }: f -> { status: 200, body: f, content_type: "text/html" }
    | failed e -> { status: 500, body: e, content_type: "text/plain" }
! [*] |> orisha:static-router(name: "site")

listen-port(): port |> orisha:serve(port)
| shutdown s |> std/io:print.ln(s)
| failed f |> std/io:print.ln(f)
