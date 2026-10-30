# ساخت و اجرای EMQX روی ویندوز

> English version: see [Windows.md](./Windows.md)

پشتیبانی از پکیج ویندوزی بعد از نسخه‌ی ۴.۳ از CI پروژه‌ی EMQX حذف شد و
لانچرهای batch هم در اواخر ۲۰۲۵ از مخزن پاک شدند. این سند بیلد ویندوزی را
همان‌طور که دوباره روی شاخه‌ی ۶.۳ راه‌اندازی شده توضیح می‌دهد.

نوشته و تأیید شده روی:

| | |
| --- | --- |
| سیستم‌عامل | Windows Server 2025 (ویندوز ۱۱ و Server 2022 هم به همین شکل) |
| EMQX | 6.3.2 (شاخه‌ی `patch-6.3.2`) |
| Erlang/OTP | فورک `emqx/otp` نسخه‌ی **OTP-28.4.1-7**، ساخته‌شده از سورس (erts 16.3) |
| Elixir | 1.19.1 (بیلدشده برای OTP 28) |
| زنجیره‌ی ابزار | MSVC 17.14 (VS 2022 Build Tools)، MSYS2، CMake 3.31.9، NASM 2.16.03، Rust 1.88.0، protoc 36.2 |
| OpenSSL | 3.6.5، استاتیک، ساخته‌شده از سورس |

---

## فهرست مطالب

1. [پیش از شروع](#۱-پیش-از-شروع)
2. [چه چیزی در بیلد ویندوزی هست و چه چیزی نیست](#۲-چه-چیزی-در-بیلد-ویندوزی-هست-و-چه-چیزی-نیست)
3. [پیش‌نیازها](#۳-پیشنیازها)
4. [ساخت EMQX](#۴-ساخت-emqx)
5. [مثال عملی — کامندهای دقیق](#۵-مثال-عملی--کامندهای-دقیق)
6. [اجرای بروکر](#۶-اجرای-بروکر)
7. [رفع اشکال](#۷-رفع-اشکال)
8. [مرجع: هر اسکریپت چه می‌کند](#۸-مرجع-هر-اسکریپت-چه-میکند)

---

## ۱. پیش از شروع

### همه چیز را در مسیرهای بدون فاصله نصب کنید

از `C:\erlang\...` و `C:\elixir\...` استفاده کنید، نه `C:\Program Files\...`.
چند وابستگی (`mysql`، `ranch`) با `erlang.mk` ساخته می‌شوند که مقدار `ERLC` را
بدون کوتیشن از `cygpath` رد می‌کند. فاصله در مسیر باعث این خطا می‌شود:

```
erlc: Error executing '"\"C:\Program Files\erl-28.4.1\...'
```

### قبل از اعتماد به باینری‌ها، CPU را بررسی کنید

این بیلد کد نیتیو تولید می‌کند. اگر CPU شما قدیمی‌تر از Haswell (۲۰۱۳) است،
**باید** تنظیم portable مربوط به Snappy را که در [بخش ۷](#۷-رفع-اشکال) توضیح
داده شده نگه دارید. این تنظیم در همین مخزن پیش‌فرض است، ولی اگر فلگ‌های بیلد را
تغییر دادید اهمیت پیدا می‌کند.

```bash
grep -m1 flags /proc/cpuinfo | tr ' ' '\n' | grep -E '^(avx|avx2|bmi2)$'
```

خروجی خالی یعنی AVX/BMI2 ندارید، و هر کتابخانه‌ای که با آن دستورات ساخته شود
هنگام اجرا با خطای «دستور غیرمجاز» می‌میرد.

### فضای دیسک و زمان

حدود **۲۵ گیگابایت فضای خالی** و چند ساعت وقت در نظر بگیرید. فقط بیلد OTP
پچ‌شده حدود یک ساعت طول می‌کشد و RocksDB سی تا پنجاه دقیقه. هر دو یک‌بار برای
همیشه‌اند.

---

## ۲. چه چیزی در بیلد ویندوزی هست و چه چیزی نیست

### حذف‌شده‌ها

اسکریپت `build` وقتی `SYSTEM=windows` باشد این‌ها را خاموش می‌کند:

| وابستگی | کلید | چه چیزی را از دست می‌دهید |
| --- | --- | --- |
| quicer (msquic) | `BUILD_WITHOUT_QUIC=on` | لیسنرهای MQTT روی QUIC. |
| jq | `BUILD_WITHOUT_JQ=on` | تابع `jq()` در موتور قواعد. jq فیلترهایش را در یک port program خارجی اجرا می‌کند که با اسکریپت autotools ساخته می‌شود و مسیر ویندوزی ندارد. `jq_port_sup` به ازای هر scheduler یک فرزند می‌سازد، پس اپلیکیشن بالا نمی‌آید و کل نود را پایین می‌کشد — به همین دلیل به‌جای اینکه خراب عرضه شود، از ریلیز بیرون گذاشته شده. |
| bcrypt | `BUILD_WITHOUT_BCRYPT=on` | استفاده از `bcrypt` به‌عنوان `password_hash_algorithm`. NIF آن به `sys/queue.h`، `err.h`، `unistd.h` و pthreads نیاز دارد؛ MSVC هیچ‌کدام را ندارد و mingw-w64 هم نه `sys/queue.h` دارد و نه `err.h`. در `emqx_machine_boot` خودِ `bcrypt` در `?OPTIONAL_APPS` فهرست شده، پس نود بدون آن سالم بالا می‌آید — از `pbkdf2` یا `sha256` استفاده کنید. |

### موجود، ولی نیازمند دست‌کاری

این‌ها کد نیتیو دارند که در upstream مسیر ویندوزی سالم ندارد؛ `scripts/windows/`
آن‌ها را می‌سازد:

| وابستگی | چگونه |
| --- | --- |
| **rocksdb** | `build-rocksdb.sh` — با CMake و MSVC، به‌همراه Snappy و LZ4 به‌صورت کتابخانه‌ی استاتیک. در نتیجه durable sessions و بک‌اند `builtin_local` کار می‌کنند. |
| **ezstd** | `build-ezstd.sh` — سورس‌های zstd 1.5.2 و خود NIF را با `cl.exe` کامپایل می‌کند و هم `.dll` و هم `.so` تولید می‌کند. |
| **crc32cer** | `build-crc32cer.sh` — یک NIF اجباری از نوع `on_load`؛ بدون آن نود abort می‌کند. فایل `crc32c_config.h` را خودش می‌نویسد. |
| **lz4b** | `build-lz4b.sh` — آن هم NIF اجباری `on_load`. یک `strings.h` خالی به‌عنوان shim فراهم می‌کند. |
| **datalayers**، **greptimedb_rs** | `build-rust-nif.sh` — NIFهای زبان Rust که هوک upstream آن‌ها `./do_compile.sh` است. rebar3 هوک‌ها را از طریق `cmd.exe` اجرا می‌کند که نمی‌تواند اسکریپت shell را اجرا کند، و آن اسکریپت خروجی را `.so` نام‌گذاری می‌کند در حالی که `erlang:load_nif/2` روی ویندوز `.dll` می‌خواهد. |

`sasl_auth` همچنان هوک‌هایش را به `(linux|darwin|solaris)` محدود می‌کند،
پس NIF آن ساخته نمی‌شود — فقط احراز هویت Kerberos/GSSAPI تحت تأثیر است.

بقیه‌ی موارد — Kafka، Postgres، MySQL و سایر یکپارچه‌سازی‌های داده — عادی ساخته
می‌شوند.

### عمداً تک‌نودی

فایل `bin\emqx.cmd` مقدار `node.db_backend` را به‌جای `rlog` پیش‌فرض، روی
`mnesia` تنظیم می‌کند؛ بیلد ویندوزی برای اجرای تک‌نود در نظر گرفته شده است.

---

## ۳. پیش‌نیازها

### ۳.۱ ابزارهای بیلد ویژوال استودیو

چند وابستگی NIFهایی به زبان C/C++ دارند. port compiler مربوط به rebar3 روی
ویندوز از `cl.exe` و `link.exe` استفاده می‌کند — **MinGW جایگزین نیست**.

فایل `vs_BuildTools.exe` را از
<https://visualstudio.microsoft.com/downloads/> دانلود کنید
(بخش Tools for Visual Studio ← Build Tools for Visual Studio 2022) و سپس:

```bat
vs_BuildTools.exe --quiet --wait --norestart ^
  --add Microsoft.VisualStudio.Workload.VCTools ^
  --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 ^
  --add Microsoft.VisualStudio.Component.Windows11SDK.26100
```

نصب Windows SDK اختیاری نیست: فایل‌های `sql.h`، `sqlext.h` و `odbc32.lib` را
فراهم می‌کند که اپلیکیشن `odbc` در OTP به آن‌ها نیاز دارد (بخش ۳.۵).

بررسی:

```bat
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" x64
cl
```

خروجی `cl` باید `Microsoft (R) C/C++ Optimizing Compiler Version 19.xx` باشد.

### ۳.۲ نصب MSYS2

اسکریپت‌های بیلد با `bash` و `escript` نوشته شده‌اند. MSYS2 را از
<https://www.msys2.org/> نصب کنید (مسیر پیش‌فرض `C:\msys64`) و بعد در شل
MSYS2:

```bash
pacman -Syu                     # اگر خواست، شل را ببندید و دوباره باز کنید
pacman -S --needed make cmake jq zip unzip p7zip curl git patch perl tar diffutils
```

Cygwin هم کار می‌کند — `scripts/get-distro.sh` هر سه‌ی `CYGWIN*`، `MSYS*` و
`MINGW*` را به `windows` نگاشت می‌کند — ولی این بیلد با MSYS2 آزموده شده است.

> **ترتیب PATH مهم است.** MSYS2 یک `link.exe` از نوع GNU دارد که لینکر مایکروسافت
> را پنهان می‌کند، و `C:\Windows\System32\find.exe` هم `find` پازیکس را پنهان
> می‌کند. فایل `scripts/windows/build-env.sh` این را حل می‌کند: اول MSVC، بعد
> `/usr/bin` و در آخر مسیرهای ویندوز. اسکریپت `build` هم `FIND` و `TAR` را به
> مسیر `/usr/bin` قفل می‌کند.

### ۳.۳ نصب CMake، NASM، protoc و Rust

| ابزار | چرا | مسیر مورد انتظار |
| --- | --- | --- |
| **CMake 3.x** (نسخه‌ی نیتیو ویندوز، **نه** نسخه‌ی MSYS2) | RocksDB با generator ویژوال استودیو پیکربندی می‌شود و CMake موجود در MSYS2 نمی‌تواند آن را هدایت کند. حتماً ۳.x باشد نه ۴.x: فایل `c_src/CMakeLists.txt` و LZ4 هنوز `cmake_minimum_required 3.5` اعلام می‌کنند. | `C:\cmake\cmake-3.31.9-windows-x86_64` |
| **NASM** | کتابخانه‌ی `aws-lc-sys` که از طریق لایه‌ی TLS در NIFهای Rust می‌آید، با NASM اسمبل می‌شود. | `C:\nasm\nasm-2.16.03` |
| **protoc** | اسکریپت بیلد `greptimedb_rs` آن را اجرا می‌کند. | `C:\protoc` |
| **Rust** (از طریق rustup) | `datalayers` و `greptimedb_rs` هر دو NIF زبان Rust هستند. | `CARGO_HOME=C:\rust\.cargo` و `RUSTUP_HOME=C:\rust\.rustup` |

دانلودها:

```powershell
# CMake 3.31.9 (فایل zip، نیازی به نصب‌کننده نیست)
# https://github.com/Kitware/CMake/releases/download/v3.31.9/cmake-3.31.9-windows-x86_64.zip

# NASM 2.16.03
# https://www.nasm.us/pub/nasm/releasebuilds/2.16.03/win64/nasm-2.16.03-win64.zip

# protoc
# https://github.com/protocolbuffers/protobuf/releases  (فایل protoc-*-win64.zip)

# Rust
# https://win.rustup.rs/x86_64  -> rustup-init.exe
$env:CARGO_HOME  = "C:\rust\.cargo"
$env:RUSTUP_HOME = "C:\rust\.rustup"
.\rustup-init.exe -y --default-toolchain stable --profile minimal
```

این مسیرها پیش‌فرض‌های `scripts/windows/build-env.sh` هستند؛ اگر چیدمان شما
فرق دارد، متغیرهای `CMAKE_HOME`، `NASM_HOME`، `PROTOC_HOME`، `CARGO_HOME` یا
`RUSTUP_HOME` را در محیط تنظیم کنید.

### ۳.۴ نصب OpenSSL (استاتیک)

ماژول `crypto` در OTP به OpenSSL نیاز دارد و روی ویندوز همان چیدمانی را
انتظار دارد که نصب‌کننده‌ی رسمی OpenSSL می‌سازد، با کتابخانه‌های **استاتیک**:

```
C:\OpenSSL-Win64\include\openssl\...
C:\OpenSSL-Win64\lib\VC\x64\MD\libcrypto_static.lib
C:\OpenSSL-Win64\lib\VC\x64\MD\libssl_static.lib
```

می‌توانید از نصب‌کننده‌ی آماده در <https://slproweb.com/products/Win32OpenSSL.html>
استفاده کنید (نسخه‌ی کامل، نه «Light»). برای ساخت از سورس:

```bash
# به یک perl نیتیو ویندوز نیاز دارد. نسخه‌ی portable از Strawberry Perl:
#   https://strawberryperl.com/   (فایل zip، استخراج در C:\strawberry)
cd /c/src/openssl-3.6.5
perl Configure VC-WIN64A --prefix=C:/OpenSSL-Win64 no-shared
nmake && nmake install
```

دو دام:

* **`Configure` پرل MSYS را رد می‌کند** با پیام
  *"This perl implementation doesn't produce Windows like paths"*. از
  Strawberry Perl استفاده کنید.
* **Strawberry را فقط بین مسیرهای MSVC و `/usr/bin` در PATH بگذارید.** اگر جلوتر
  از MSVC باشد، `link.exe` همراهش لینکر مایکروسافت را پنهان می‌کند و خطای
  `link: extra operand '/dll'` می‌گیرید.

اگر با `no-shared` بسازید، کتابخانه‌ها با نام `libcrypto.lib` و `libssl.lib`
تولید می‌شوند؛ OTP دنبال نام‌های `_static` می‌گردد، پس کپی کنید:

```bash
mkdir -p /c/OpenSSL-Win64/lib/VC/x64/MD
cp /c/OpenSSL-Win64/lib/libcrypto.lib /c/OpenSSL-Win64/lib/VC/x64/MD/libcrypto_static.lib
cp /c/OpenSSL-Win64/lib/libssl.lib    /c/OpenSSL-Win64/lib/VC/x64/MD/libssl_static.lib
```

وقتی `configure` در OTP این را چاپ کند یعنی درست شده:

```
checking for OpenSSL in C:/OpenSSL-Win64... static libcrypto_static library in C:/OpenSSL-Win64/lib/VC/x64/MD
```

### ۳.۵ ارلنگ/OTP — داشتن OTP پچ‌شده اجباری است

EMQX روی نسخه‌ی استاندارد Erlang/OTP اجرا **نمی‌شود**. این بروکر روی فورک
[`emqx/otp`](https://github.com/emqx/otp) بالا می‌آید که تغییراتی را حمل می‌کند
که EMQX در زمان اجرا به آن‌ها نیاز دارد. روی OTP استاندارد نود با
`unsupported_otp_version` متوقف می‌شود و این بررسی تشریفاتی نیست. دو چیزی که
واقعاً از آن محافظت می‌کند:

* **`{packet, mqtt}`** — تجزیه‌ی طول فریم MQTT که در **کد C** شبیه‌ساز پیاده‌سازی
  شده (`erts/emulator/drivers/common/packet_parser.c`،
  `erts/emulator/beam/atom.names`، `erl_bif_port.c`). روی OTP استاندارد،
  `inet:setopts(S, [{packet, mqtt}])` مقدار `{error, einval}` برمی‌گرداند. چون
  در erts است، با وصله‌کردن فایل‌های `.beam` قابل جبران نیست.
* **`mnesia_hook`** — ماژولی از `mnesia` که `mria` استفاده می‌کند؛ روی OTP
  استاندارد `undef` است. توجه کنید که تنظیم `EMQX_NODE__DB_BACKEND=mnesia` این
  را دور نمی‌زند: تابع `mria_config:backend()` مقدار `rlog` را هاردکد کرده است.

ماژول `ssl` هم تغییرات فورک را دارد.

روی هر نصب OTP می‌توانید بررسی کنید:

```bash
erl -noshell -eval '
  {ok,L}=gen_tcp:listen(0,[]),
  io:format("packet,mqtt: ~p~n",[inet:setopts(L,[{packet,mqtt}])]),
  io:format("mnesia_hook: ~p~n",[code:ensure_loaded(mnesia_hook)]),
  halt().'
```

OTP پچ‌شده `ok` و `{module,mnesia_hook}` چاپ می‌کند. نسخه‌ی استاندارد
`{error,einval}` و `{error,nofile}`.

هیچ باینری ویندوزی از `emqx/otp` منتشر نشده، پس باید یک‌بار ساخته شود.

#### ۳.۵.۱ کلون، و خاموش‌کردن تبدیل CRLF پیش از هر کاری

```bash
git clone https://github.com/emqx/otp.git /c/src/emqx-otp
cd /c/src/emqx-otp
git checkout OTP-28.4.1-7
```

درخت OTP فایل `.gitattributes` ندارد، پس اگر `core.autocrlf=true` به‌صورت سراسری
تنظیم باشد کل درخت با CRLF چک‌اوت می‌شود و بیلد در عمق شبیه‌ساز با این خطا شکست
می‌خورد:

```
ops.tab(27): '' is not a recognized type
```

آن `''` در واقع یک کاراکتر carriage return است که روی کوتیشن ابتدایی پیام واقعی
نوشته شده. این را **در سطح همان مخزن** درست کنید تا تنظیم سراسری شما دست‌نخورده
بماند:

```bash
git config core.autocrlf false
git config core.eol lf
git rm --cached -r . >/dev/null && git reset --hard
```

#### ۳.۵.۲ اعمال سه پچ OTP

هر سه باگ خود بیلد ویندوزی OTP هستند، نه چیزی مخصوص EMQX:

```bash
git apply /c/src/emqx/scripts/windows/otp-28.4.1-7-windows.patch
```

هرکدام چه چیزی را درست می‌کنند:

۱. **`erts/emulator/Makefile.in`** — شاخه‌ی win32 مقدار `DEP_FLAGS` را از
   `$(INCLUDES)` می‌گیرد به‌جای `$(DEP_INCLUDES)` (شاخه‌ی غیر win32 چند خط
   پایین‌تر همان دومی را استفاده می‌کند)، در نتیجه مرحله‌ی `depend` فایل
   `prim_file_nif.h` را پیدا نمی‌کند. اگر `erts/emulator/win32/Makefile` از قبل
   تولید شده، آنجا را هم اصلاح کنید.

۲. **`erts/etc/win32/msys_tools/vc/cc.sh`** — یک شاخه‌ی
   `-std=c++*|-std=gnu++*` پیش از `-l*)` اضافه می‌کند که آن را به
   `/std:c++NN /Zc:__cplusplus` ترجمه می‌کند. گزینه‌های ناشناخته به **لینکر**
   فرستاده می‌شوند، پس `-std=c++17` هرگز به `cl.exe` نمی‌رسد و `configure` پیام
   *«JIT disabled due to lack of compiler with C++17 support»* می‌دهد. وجود
   `/Zc:__cplusplus` هم لازم است چون در غیر این صورت MSVC مقدار `__cplusplus` را
   `199711L` گزارش می‌کند و دقیقاً همین مقدار است که آزمون بررسی‌اش می‌کند.
   خروجی درست `checking for C++17 support... yes` است و فایل
   `bin/win32/beam.jit.dll` ساخته می‌شود.

۳. **`erts/etc/win32/msys_tools/vc/ld.sh`** — الگوی مسیر کتابخانه را از
   `-L/*|-L.*)` به `-L?*)` گسترش می‌دهد. الگوهای اصلی فقط مسیر مطلق پازیکس
   (`-L/...`) یا نسبی (`-L....`) را می‌گیرند، اما `configure` مقدار
   `SSL_LIBDIR = C:/OpenSSL-Win64/lib/VC/x64/MD` را ثبت می‌کند که مسیر درایو
   ویندوزی است. با هیچ‌کدام مطابقت ندارد، به شاخه‌ی عمومی می‌افتد و عیناً به‌صورت
   `/LC:/OpenSSL-Win64/...` به `link.exe` می‌رسد که آن را با
   `LINK : warning LNK4044: unrecognized option ...; ignored` کنار می‌گذارد.
   خطای واقعی خط بعد ظاهر می‌شود:
   `LINK : fatal error LNK1181: cannot open input file 'libcrypto_static.lib'`
   — که نام یک **کتابخانه** را می‌برد، پس شبیه «OpenSSL نصب نیست» به نظر می‌رسد.
   تشخیص واقعی همان هشدار LNK4044 بالای آن است.

#### ۳.۵.۳ رد کردن اپلیکیشن‌های wx

دستور `otp_build boot -a` **همه‌ی** اپلیکیشن‌ها را می‌سازد و اینجا چیزی wxWidgets
را فراهم نمی‌کند، پس `wx` بی‌صدا هیچ beam‌ای تولید نمی‌کند. بعد اپلیکیشن‌هایی که
ماژول‌هایشان `-behaviour(wx_object)` دارند شکست می‌خورند، چون OTP هشدارها را
خطا حساب می‌کند:

```
dbg_wx_filedialog_win.erl:25:2: behaviour wx_object undefined
make: *** [Makefile:510: libs] Error 2
```

به‌جای وصله‌کردن makefileها از سازوکار خود OTP استفاده کنید — فایل `lib/Makefile`
محتوای `lib/SKIP-APPLICATIONS` را می‌خواند و آن نام‌ها را از `SUB_DIRECTORIES`
حذف می‌کند، هم برای هدف `libs` و هم `release`:

```bash
printf 'wx\ndebugger\net\nobserver\n' > lib/SKIP-APPLICATIONS
```

EMQX به هیچ‌کدام نیاز ندارد؛ `observer` از قبل در `?OPTIONAL_APPS` مربوط به
`emqx_machine_boot` فهرست شده است.

#### ۳.۵.۴ ساخت و نصب

از شلی که MSVC روی PATH آن است:

```bash
export ERL_TOP=/c/src/emqx-otp
cd "$ERL_TOP"

eval "$(./otp_build env_win32 x64)"
./otp_build autoconf
./otp_build configure --with-ssl=C:/OpenSSL-Win64 --disable-dynamic-ssl-lib \
    --without-wx --without-javac
./otp_build boot -a
./otp_build release -a /c/erlang/28.4.1-7-emqx
```

بعد — این مرحله را راحت می‌شود جا انداخت — اسکریپت‌های سطح بالا را بسازید.
دستور `release -a` پوشه‌های `lib/`، `releases/` و `erts-*/` را نصب می‌کند اما
**هیچ `bin/`ای** نمی‌سازد:

```bash
cd /c/erlang/28.4.1-7-emqx && cmd.exe //c "Install.exe -s"
```

سه کاری که در آن شل **نباید** انجام دهید:

* **پرچم `--without-odbc` را اضافه نکنید.** وسوسه‌انگیز است، چون برای ساختن
  EMQX هیچ درایور ODBC لازم نیست — اما `odbc` یک وابستگی واقعی است:
  `emqx_bridge_quasardb` و `emqx_bridge_snowflake` هر دو آن را در
  `extra_applications` خود دارند، پس بدون آن ریلیز اصلاً assemble نمی‌شود. به
  شکل بدی هم شکست می‌خورد: بخش ارلنگی `odbc` کامپایل می‌شود، فقط
  `lib/odbc/configure` اجرا نمی‌شود، در نتیجه `c_src/win32/Makefile` تولید
  نمی‌شود و `boot -a` با `No rule to make target 'win32/Makefile'` می‌ایستد.
  `lib/odbc/SKIP` هم نوشته نمی‌شود، پس اپلیکیشن تمیز هم حذف نمی‌شود. بازیابی
  بدون reconfigure کامل:

  ```bash
  cd lib/odbc && rm -f SKIP
  ./configure --build=local-x86_64-pc-windows --host=local-x86_64-pc-windows \
      --target=local-x86_64-pc-windows CC=cc.sh CXX=cc.sh RANLIB=true AR=ar.sh \
      --cache-file=./odbc.config.cache
  ```

  از یک فایل cache **تازه** استفاده کنید — فایل سطح بالا با اجرای حاوی
  `--without-odbc` پر شده و هیچ نتیجه‌ی probe مربوط به ODBC ندارد. موفقیت یعنی
  `checking for sql.h... yes` و
  `config.status: creating c_src/win32/Makefile`.

* **متغیر `MSYS2_ARG_CONV_EXCL='*'` را تنظیم نکنید.** اسکریپت‌های کمکی NIF در
  `scripts/windows/` به آن نیاز دارند، ولی `otp_build` نه: این ابزار
  `cmd //C` صدا می‌زند و به بازنویسی آن توسط MSYS2 به `/C` تکیه دارد. با خاموش
  بودن تبدیل، `cmd.exe` رشته‌ی `//C` را می‌بیند، چیزی برای اجرا پیدا نمی‌کند و
  منتظر ورودی می‌ماند — بیلد صرفاً معلق می‌شود.

* **Strawberry Perl را روی PATH نگذارید.** اسکریپت
  `erts/emulator/utils/make_preload` به‌صورت `` `w32_path.sh -d $file` `` فراخوانی
  می‌کند و یک perl نیتیو، backtick را از طریق `cmd.exe` اجرا می‌کند که نمی‌تواند
  فایل `.sh` را اجرا کند. نشانه‌اش این است:
  `beams.rc(26) : error RC2135 : file not found:` به‌همراه `ERLANG_CODE ""` خالی.
  توجه کنید `configure` مقدار `PERL` را داخل makefileهای تولیدشده می‌نویسد، پس
  اصلاح PATH بعد از آن کافی نیست — باید `configure` را دوباره اجرا کنید تا
  `PERL = /c/msys64/usr/bin/perl` ثبت شود.

#### ۳.۵.۵ معرفی آن به بیلد

فایل `scripts/windows/build-env.sh` از قبل پیش‌فرض
`ERL_HOME=/c/erlang/28.4.1-7-emqx` را دارد و اگر موجود باشد همان را ترجیح
می‌دهد، پس اگر در همان مسیر نصب کرده‌اید نیازی به ویرایش نیست. در غیر این صورت
`ERL_HOME` را خودتان export کنید.

### ۳.۶ نصب Elixir

ریلیز توسط Mix ساخته می‌شود، پس Elixir لازم است نه اختیاری. از بیلدی استفاده
کنید که **برای OTP 28** ساخته شده:

* <https://github.com/elixir-lang/elixir/releases/tag/v1.19.1> ← فایل `elixir-otp-28.zip`

در `C:\elixir\1.19.1` استخراج کنید.

هر دو را از یک شل تازه بررسی کنید:

```
> erl -noshell -eval "io:format(\"~s~n\",[erlang:system_info(otp_release)]),halt()."
28
> elixir --version
Elixir 1.19.1 (compiled with Erlang/OTP 28)
```

---

## ۴. ساخت EMQX

### ۴.۱ همان یک کامند

از یک خط فرمان `cmd.exe` در ریشه‌ی مخزن:

```bat
scripts\windows\build.cmd emqx-enterprise
```

کل ماجرا همین wrapper است: نصب ویژوال استودیو را با `vswhere` پیدا می‌کند،
`vcvarsall.bat x64` را اجرا می‌کند، محیط حاصل را به MSYS2 تحویل می‌دهد و از
آنجا وابستگی‌ها را می‌گیرد، هوک‌های وابستگی‌های نیتیو را وصله می‌کند، NIFها را
از پیش می‌سازد و `make` را اجرا می‌کند. `vcvarsall.bat` باید از `cmd.exe` اجرا
شود و تنها دلیل وجود یک فایل batch همین است.

در نسخه‌ی ۶.x تنها پروفایل ریلیز همین `emqx-enterprise` است — در `Makefile`
مقدار `REL_PROFILES := emqx-enterprise` تعریف شده و پروفایل متن‌باز جداگانه‌ای
برای ساختن وجود ندارد. لایسنسی که در زمان اجرا اعمال می‌شود موضوع جداگانه‌ای
است؛ خود ریلیز هنگام بوت شرایطش را چاپ می‌کند.

### ۴.۲ اجرای دستی مراحل

```bat
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" x64
set MSYSTEM=MSYS
set MSYS2_PATH_TYPE=inherit
set CHERE_INVOKING=1
C:\msys64\usr\bin\bash.exe -lc "cd /c/src/emqx && source scripts/windows/build-env.sh && make mix-deps-get && ./scripts/windows/patch-native-deps.sh && make emqx-enterprise"
```

متغیر `MSYS2_PATH_TYPE=inherit` الزامی است: بدون آن شل لاگین MSYS2 مقدار `PATH`
را از نو می‌سازد و مسیرهای MSVC از دست می‌روند و خطای
`ERROR: cl not found on PATH` می‌گیرید.

### ۴.۳ خروجی

```
_build\emqx-enterprise\rel\emqx
```

حدود ۲۲۶ مگابایت. رانتایم ارلنگ داخلش جاسازی شده (`erts-16.3\`)، پس این پوشه
خودبسنده است — ماشین مقصد نیازی به نصب ارلنگ ندارد.

برای ساخت پکیج zip:

```bat
scripts\windows\build.cmd emqx-enterprise-tgz
```

روی ویندوز، `build` ریلیز را با `7z` در این مسیر بسته‌بندی می‌کند:
`_packages\emqx-enterprise\emqx-enterprise-<vsn>-windows-amd64.zip`

### ۴.۴ بیلد مجدد تمیز

بیلد معمولی از وابستگی‌های کامپایل‌شده‌ی قبلی استفاده می‌کند. معمولاً همین را
می‌خواهید، ولی **beamهای کامپایل‌شده فلگ‌هایی را که با آن ساخته شده‌اند به یاد
می‌آورند**. اگر یک exclusion (`BUILD_WITHOUT_*`) یا فلگ بیلد نیتیو را عوض کردید،
وابستگی مربوطه را از `_build` پاک کنید وگرنه رفتار قدیمی باقی می‌ماند:

```bash
rm -rf _build/emqx-enterprise/lib/mria deps/mria/_build   # مثال: تغییر وضعیت rocksdb
rm -rf _build/emqx-enterprise/rel                         # اجبار به ساخت دوباره‌ی ریلیز
```

---

## ۵. مثال عملی — کامندهای دقیق

این دقیقاً همان چیدمانی است که بیلد ویندوزی ۶.۳.۲ با آن تولید شد. همه‌ی مسیرها
روی `C:\` و بدون فاصله هستند.

### ۵.۱ چیدمان

| چه چیزی | مسیر |
| --- | --- |
| سورس EMQX | `C:\xampp\htdocs\emqx` |
| سورس OTP (فورک) | `C:\xampp\htdocs\emqx-otp` |
| نصب OTP پچ‌شده | `C:\erlang\28.4.1-7-emqx` |
| OTP استاندارد (فقط برای bootstrap) | `C:\erlang\28.4.1` |
| Elixir | `C:\elixir\1.19.1` |
| CMake | `C:\cmake\cmake-3.31.9-windows-x86_64` |
| NASM | `C:\nasm\nasm-2.16.03` |
| protoc | `C:\protoc` |
| Rust | `C:\rust\.cargo` و `C:\rust\.rustup` |
| OpenSSL | `C:\OpenSSL-Win64` |
| MSYS2 | `C:\msys64` |
| VS Build Tools | `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools` |

### ۵.۲ پیش‌نیازها

```powershell
# --- ابزارهای بیلد ویژوال استودیو ----------------------------------------
.\vs_BuildTools.exe --quiet --wait --norestart `
  --add Microsoft.VisualStudio.Workload.VCTools `
  --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
  --add Microsoft.VisualStudio.Component.Windows11SDK.26100

# --- MSYS2 ----------------------------------------------------------------
# در C:\msys64 نصب کنید، سپس در شل MSYS2:
#   pacman -Syu
#   pacman -S --needed make cmake jq zip unzip p7zip curl git patch perl tar diffutils

# --- CMake 3.31.9 ---------------------------------------------------------
Expand-Archive cmake-3.31.9-windows-x86_64.zip -DestinationPath C:\cmake

# --- NASM -----------------------------------------------------------------
Expand-Archive nasm-2.16.03-win64.zip -DestinationPath C:\nasm

# --- protoc ---------------------------------------------------------------
Expand-Archive protoc-win64.zip -DestinationPath C:\protoc

# --- Rust -----------------------------------------------------------------
$env:CARGO_HOME  = "C:\rust\.cargo"
$env:RUSTUP_HOME = "C:\rust\.rustup"
.\rustup-init.exe -y --default-toolchain stable --profile minimal

# --- Elixir 1.19.1 برای OTP 28 -------------------------------------------
Expand-Archive elixir-otp-28.zip -DestinationPath C:\elixir\1.19.1

# --- OTP استاندارد 28.4.1، فقط برای bootstrap کردن بیلد OTP ---------------
.\otp_win64_28.4.1.exe /S /D=C:\erlang\28.4.1
```

### ۵.۳ ساخت OTP پچ‌شده

```bash
# در شل MSYS2 که MSVC روی PATH آن است (بخش ۵.۴ را ببینید)
git clone https://github.com/emqx/otp.git /c/xampp/htdocs/emqx-otp
cd /c/xampp/htdocs/emqx-otp
git checkout OTP-28.4.1-7

git config core.autocrlf false
git config core.eol lf
git rm --cached -r . >/dev/null && git reset --hard

git apply /c/xampp/htdocs/emqx/scripts/windows/otp-28.4.1-7-windows.patch
printf 'wx\ndebugger\net\nobserver\n' > lib/SKIP-APPLICATIONS

export ERL_HOME=/c/erlang/28.4.1          # OTP استاندارد بیلد را bootstrap می‌کند
source /c/xampp/htdocs/emqx/scripts/windows/build-env.sh
export ERL_TOP=/c/xampp/htdocs/emqx-otp
cd "$ERL_TOP"

eval "$(./otp_build env_win32 x64)"
./otp_build autoconf
./otp_build configure --with-ssl=C:/OpenSSL-Win64 --disable-dynamic-ssl-lib \
    --without-wx --without-javac
./otp_build boot -a
./otp_build release -a /c/erlang/28.4.1-7-emqx

cd /c/erlang/28.4.1-7-emqx && cmd.exe //c "Install.exe -s"
```

بررسی اینکه واقعاً فورک نصب شده است:

```bash
/c/erlang/28.4.1-7-emqx/bin/erl.exe -noshell -eval '
  {ok,L}=gen_tcp:listen(0,[]),
  io:format("packet,mqtt: ~p~n",[inet:setopts(L,[{packet,mqtt}])]),
  io:format("mnesia_hook: ~p~n",[code:ensure_loaded(mnesia_hook)]),
  halt().'
# packet,mqtt: ok
# mnesia_hook: {module,mnesia_hook}
```

### ۵.۴ ساخت EMQX

```bat
cd C:\xampp\htdocs\emqx
scripts\windows\build.cmd emqx-enterprise
```

نتیجه: `C:\xampp\htdocs\emqx\_build\emqx-enterprise\rel\emqx`

### ۵.۵ اجرا و تست

```bat
cd C:\xampp\htdocs\emqx\_build\emqx-enterprise\rel\emqx
bin\emqx.cmd start
bin\emqx_ctl.cmd status
```

خروجی مورد انتظار:

```
Node 'emqx@127.0.0.1' 6.3.2 is started
```

تست سرتاسری MQTT با کلاینت `emqtt` که از قبل داخل ریلیز هست:

```bash
cd /c/xampp/htdocs/emqx/_build/emqx-enterprise/rel/emqx
/c/erlang/28.4.1-7-emqx/bin/erl.exe -noshell \
  -pa lib/emqtt-*/ebin -pa lib/cowlib-*/ebin -pa lib/gproc-*/ebin -pa lib/getopt-*/ebin -eval '
{ok,S}=emqtt:start_link([{host,"127.0.0.1"},{port,1883},{clientid,<<"sub">>}]),{ok,_}=emqtt:connect(S),
{ok,_,[1]}=emqtt:subscribe(S,{<<"t/1">>,1}),
{ok,P}=emqtt:start_link([{host,"127.0.0.1"},{port,1883},{clientid,<<"pub">>}]),{ok,_}=emqtt:connect(P),
{ok,_}=emqtt:publish(P,<<"t/1">>,<<"hello">>,1),
receive {publish,M} -> io:format("RECEIVED: ~s~n",[maps:get(payload,M)]) after 5000 -> io:format("TIMEOUT~n") end,
halt().'
# RECEIVED: hello
```

### ۵.۶ اجرای نود دوم کنار یک EMQX موجود

اگر روی ماشین از قبل یک EMQX دیگر اجرا می‌شود، نود جدید را از سر راه آن کنار
بکشید. تابع `ekka_dist:port/1` پورت توزیع را برابر
**`۴۳۷۰ + رقم‌های انتهایی نام نود`** حساب می‌کند، پس نامی که رقم انتهایی ندارد با
پیش‌فرض ۴۳۷۰ تداخل می‌کند — یک پسوند عددی انتخاب کنید، نه صرفاً نام متفاوت:

```bat
set EMQX_NODE__NAME=emqxtest9@127.0.0.1
set EMQX_RPC__PORT_DISCOVERY=manual
set EMQX_RPC__SERVER_PORT=5470
set EMQX_LISTENERS__TCP__DEFAULT__BIND=1884
set EMQX_LISTENERS__WS__DEFAULT__BIND=8085
set EMQX_DASHBOARD__LISTENERS__HTTP__BIND=18084
bin\emqx.cmd start
```

---

## ۶. اجرای بروکر

```bat
cd _build\emqx-enterprise\rel\emqx
bin\emqx.cmd start
bin\emqx_ctl.cmd status
```

فایل `bin\emqx.cmd` از این دستورات پشتیبانی می‌کند: `start`، `stop`، `restart`،
`console`، `ping`، `attach` / `remote_console`، `ctl`، `list` و
`install` / `uninstall` برای ثبت نود به‌عنوان سرویس ویندوزی از طریق `erlsrv.exe`.

دو نکته که دانستنشان ارزش دارد:

* **`console` به یک کنسول واقعی نیاز دارد.** این دستور `erl` را بدون `-noinput`
  اجرا می‌کند، پس با ورودی ریدایرکت‌شده شل ارلنگ بالا نمی‌آید و بوت برای همیشه
  روی `Command table is initializing.` معلق می‌ماند، در حالی که پورت توزیع را هم
  نگه داشته است. برای استفاده‌ی اسکریپتی یا غیرتعاملی از `start` استفاده کنید یا
  `-noinput` اضافه کنید.
* **`bin\emqx` و `bin\emqx.cmd` دو لانچر متفاوت** برای یک ریلیز هستند؛ روی
  ویندوز از نسخه‌ی `.cmd` استفاده کنید. فایل `bin\emqx.bat` که خود Mix تولید
  می‌کند هنگام ساخت ریلیز حذف می‌شود، دقیقاً به این دلیل که نتواند `emqx.cmd` را
  پنهان کند — در `PATHEXT` پیش‌فرض، پسوند `.BAT` قبل از `.CMD` می‌آید.

---

## ۷. رفع اشکال

### نود روی دایرکتوری خالی بالا می‌آید، ولی در هر اجرای بعدی VM را می‌کشد

کد خروج `132` در شلی که سیگنال‌ها را گزارش می‌کند؛ استثنای ویندوزی `0xC000001D`
(دستور غیرمجاز). **هیچ خط لاگی، هیچ `erl_crash.dump` و هیچ رویدادی در Event Log
ویندوز** وجود ندارد، چون پروسه وسط اجرای یک دستور می‌میرد نه اینکه خارج شود.

علت، Snappy همراه بیلد است نه EMQX. Snappy در زمان configure تصمیم می‌گیرد که
دستورات BMI2 تولید کند یا نه، و این کار را با `check_cxx_source_compiles` روی
`_bzhi_u32` انجام می‌دهد. MSVC برای آن intrinsic به هیچ سوییچ `-mbmi2` نیاز
ندارد، پس این آزمون همیشه موفق می‌شود و `SNAPPY_HAVE_BMI2` صرف‌نظر از CPU مقصد
برابر ۱ تنظیم می‌شود. BMI2 با Haswell (۲۰۱۳) آمد، پس روی هر چیزی قدیمی‌تر،
کتابخانه در نخستین باری که بلاکی فشرده می‌شود یا فایل SST موجودی خوانده می‌شود
خطا می‌دهد.

به همین دلیل بوت اول سالم به نظر می‌رسد: نوشته‌های تازه بدون فشرده‌سازی در
memtable و WAL می‌مانند و تا اجرای بعدی چیزی SST نمی‌خواند.

اسکریپت `scripts/windows/patch-native-deps.sh` مقدار `-DSNAPPY_HAVE_BMI2=0` را
قفل می‌کند، هم‌خوان با `PORTABLE=ON` که RocksDB از قبل با آن ساخته می‌شود. اگر
میزبان بیلد و همه‌ی مقصدها قطعاً Haswell یا جدیدتر هستند، با
`EMQX_SNAPPY_BMI2=1` می‌توانید برش گردانید.

کمینه‌ترین بازتولید، بدون حضور EMQX و mnesia:

```erlang
{ok,Db} = rocksdb:open("/tmp/t", [{create_if_missing,true}]),
[rocksdb:put(Db, <<N:32>>, <<"v">>, []) || N <- lists:seq(1,2000)],
rocksdb:flush(Db, []).        %% روی CPU قدیمی‌تر از Haswell اینجا می‌میرد
```

اگر `{compression,none}` بدهید همین توالی رد می‌شود — سریع‌ترین راه تأیید تشخیص.

### خطای `'c++' is not recognized` از port compiler

متغیر `REBAR_TARGET_ARCH` تنظیم نشده است. OTP 24 مقدار `win32` را از
`erlang:system_info(system_architecture)` برمی‌گرداند؛ OTP 28 مقدار
`x86_64-pc-windows` را. افزونه‌ی `pc` پیش‌فرض‌های MSVC خود را — و وابستگی‌هایی
مثل `snappyer` و `jiffy` بخش `port_env` ویندوزی خود را — با تطبیق یک الگوی
`win32` روی همین رشته انتخاب می‌کنند، پس روی OTP 28 همه‌ی آن شاخه‌ها از کار
می‌افتند و به‌جایش پیش‌فرض‌های gcc استفاده می‌شود.

فایل `scripts/windows/build-env.sh` مقدار `REBAR_TARGET_ARCH=x86_64-win32` را
export می‌کند تا `win32` دوباره داخل آن رشته باشد. **این تنها تغییری است که
بدون آن هیچ NIFای روی ویندوز کامپایل نمی‌شود.**

توجه کنید که فیلتر هوک در **هسته‌ی** rebar3 متغیر `REBAR_TARGET_ARCH` را نادیده
می‌گیرد، و به همین دلیل `patch-native-deps.sh` الگوی هوک‌ها را هم از `"win32"`
به `"win32|windows"` گسترش می‌دهد.

### خطاهای `'cl.exe' is not recognized` یا `fatal error C1083: Cannot open include file: 'assert.h'`

یا `vcvarsall.bat x64` اجرا نشده، یا MSYS2 مقدار `PATH` را بدون مسیرهای MSVC از
نو ساخته است. داخل شل بیلد دستور `command -v cl` را بررسی کنید و مطمئن شوید
پیش از اجرای bash مقدار `MSYS2_PATH_TYPE=inherit` تنظیم شده باشد.

### خطای `link: extra operand 'some.obj'`

لینکر GNU روی PATH جلوتر از لینکر MSVC است. خروجی `link.exe --version` باید
`Microsoft (R) Incremental Linker` باشد.

### خطای `'.' is not recognized as an internal or external command`

هنگام کامپایل `datalayers` یا `greptimedb_rs` دیده می‌شود: یعنی
`scripts/windows/patch-native-deps.sh` بعد از گرفتن وابستگی‌ها اجرا نشده است.
دستور `mix deps.clean` وصله را برمی‌گرداند، پس بعد از آن دوباره اجرایش کنید.

### خطای `Missing artifact priv/<name>.so`

یکی از NIFهای نیتیو از پیش ساخته نشده است. Mix پوشه‌ی `priv/` یک وابستگی را
**پیش از** کامپایل آن symlink می‌کند، پس NIFها باید از قبل وجود داشته باشند —
کارکرد فراخوانی‌های `build_nif_now` در انتهای `patch-native-deps.sh` دقیقاً همین
است. آن اسکریپت را دوباره اجرا کنید.

### `emqx_ctl` می‌گوید «not responding to pings» در حالی که نود آشکارا بالاست

EMQX از پروتکل توزیع اختصاصی خودش استفاده می‌کند. فایل `bin\emqx.cmd` این را
تنظیم می‌کند:

```
ERL_FLAGS=-start_epmd false -epmd_module ekka_epmd -proto_dist ekka
```

هر `erl`/`escript` که لانچر اجرا می‌کند — از جمله `nodetool` که `emqx_ctl` روی
آن سوار است — از همین استفاده می‌کند. نودی که **بدون** این فلگ‌ها بالا بیاید با
`inet_tcp` ساده حرف می‌زند و در epmd معمولی ثبت می‌شود، و این دو همدیگر را
نمی‌بینند. اگر `epmd -names` نود EMQX شما را فهرست کرد، یعنی با توزیع اشتباه
اجرا شده است.

### خطای `Protocol 'ekka': register/listen error: "port 4370 is in use"`

یک نود EMQX دیگر از قبل مالک آن پورت است. بخش ۵.۶ را ببینید — به نام نود یک
پسوند عددی بدهید.

### بیلد در `quicer` یا `jq` می‌میرد

متغیر `BUILD_WITHOUT_*` متناظر به Mix نرسیده است. این متغیرها توسط `build` برای
`SYSTEM=windows` تنظیم می‌شوند؛ اگر مستقیم `mix` را صدا می‌زنید، خودتان آن‌ها را
export کنید.

### خطای `ops.tab(27): '' is not a recognized type` هنگام ساخت OTP

خطوط درخت سورس OTP با CRLF هستند. بخش ۳.۵.۱ را ببینید.

---

## ۸. مرجع: هر اسکریپت چه می‌کند

| اسکریپت | کارکرد |
| --- | --- |
| `scripts/windows/build.cmd` | نقطه‌ی ورود. ویژوال استودیو را با `vswhere` پیدا می‌کند، `vcvarsall.bat x64` را اجرا می‌کند، وجود `cl.exe` را تأیید می‌کند و سپس کار را با محیط به‌ارث‌رسیده به bash در MSYS2 می‌سپارد. |
| `scripts/windows/build-env.sh` | مقدار `PATH` را به ترتیب درست می‌سازد (MSVC ← CMake ← `/usr/bin` ← ارلنگ/الیکسیر/Rust/protoc/NASM ← مسیرهای ویندوز)، متغیر `REBAR_TARGET_ARCH` را export می‌کند، RocksDB را به کتابخانه‌های استاتیک Snappy و LZ4 اشاره می‌دهد و کامل بودن زنجیره‌ی ابزار را بررسی می‌کند. در شل MSYS2 آن را `source` کنید. |
| `scripts/windows/patch-native-deps.sh` | هوک‌های کامپایل ویندوزی را برای `ezstd`، `crc32cer`، `lz4b` و `rocksdb` اضافه یا گسترش می‌دهد؛ هوک NIFهای Rust را از مسیر bash عبور می‌دهد؛ مقدار `SNAPPY_HAVE_BMI2=0` را قفل می‌کند؛ و در پایان همه‌ی NIFهای نیتیو را از پیش می‌سازد. idempotent است. بعد از `make mix-deps-get` اجرا کنید. |
| `scripts/windows/build-rocksdb.sh` | RocksDB را با MSVC/CMake به‌همراه Snappy و LZ4 استاتیک می‌سازد و `priv/liberocksdb.dll` تولید می‌کند. |
| `scripts/windows/build-ezstd.sh` | zstd و NIF مربوط به `ezstd` را با `cl.exe` می‌سازد. |
| `scripts/windows/build-crc32cer.sh` | NIF مربوط به `crc32cer` را می‌سازد (از نوع `on_load` اجباری). |
| `scripts/windows/build-lz4b.sh` | NIF مربوط به `lz4b` را می‌سازد (از نوع `on_load` اجباری). |
| `scripts/windows/build-rust-nif.sh` | اسکریپت `do_compile.sh` یک NIF زبان Rust را از طریق bash اجرا می‌کند و سپس `priv/*.so` را به `.dll` کپی می‌کند تا `erlang:load_nif/2` آن را پیدا کند. |
| `scripts/windows/otp-28.4.1-7-windows.patch` | سه اصلاح بیلد OTP از بخش ۳.۵.۲. |

چهار اسکریپت `build-<nif>.sh` مربوط به `rocksdb`، `ezstd`، `crc32cer` و `lz4b`
idempotent هستند — اگر کتابخانه از قبل موجود باشد کاری نمی‌کنند. با `FORCE=1`
می‌توانید ساخت دوباره را اجبار کنید. `build-rust-nif.sh` چنین محافظی ندارد و
کار را به cargo می‌سپارد که خودش کش می‌کند.
