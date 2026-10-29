# JohorStudio Tether

Sony A7R II → (USB) → Raspberry Pi 5 → (WiFi/LAN, router) → Mac → `Desktop/LIVEFOLDER`

```
[A7R II] --USB--> [Pi 5 + OLED] --WiFi--> [Router] --LAN/WiFi--> [Mac: menu bar app]
                    gphoto2                                       simpan JPG ke folder
                    queue + hantar                                 (default Desktop/LIVEFOLDER)
```

Cara ia berfungsi:
- Pi jalankan `gphoto2 --capture-tethered`. Setiap kali shutter ditekan, JPG terus masuk Pi.
- Pi cari Mac sendiri (Bonjour) — tak perlu set IP.
- Pi hantar JPG ke app Mac, app semak SHA-256, kemudian simpan ke folder pilihan.
  Fail ditulis sebagai fail tersembunyi `.partial` dulu, baru ditukar nama → app lain yang
  pantau LIVEFOLDER tak akan nampak gambar separuh.
- Lepas Mac sahkan terima, fail dipindah ke `sent/` di Pi. Pi simpan **30 gambar terakhir sahaja**, yang lama dipadam.
- Kalau Mac terputus, gambar tunggu dalam `pending/` di Pi dan dihantar automatik bila Mac kembali.
- Fail bukan JPG (contoh RAW) diabaikan.

---

## 1. Barang diperlukan

- Raspberry Pi 5 + power supply rasmi 27W (penting — kamera guna USB)
- Kad microSD 16GB+
- Kabel USB kamera (Micro-USB untuk A7R II)
- Skrin OLED 0.96" SSD1306 128×64, **I2C** (4 pin: GND, VCC, SCL, SDA)

### Sambungan OLED ke Pi 5

| OLED | Pi 5 (pin fizikal) |
|------|--------------------|
| VCC  | Pin 1 (3.3V)       |
| GND  | Pin 6 (GND)        |
| SDA  | Pin 3 (GPIO2)      |
| SCL  | Pin 5 (GPIO3)      |

Paparan OLED:
```
JohorStudio Tether
CAM ILCE-7RM2
MAC Rafi-MacBook-Pro
Q:0  HANTAR:128
DSC01234.JPG
IP 192.168.1.23
```

---

## 2. Setting kamera A7R II

1. **MENU → Setup → USB Connection → PC Remote**
2. **MENU → Setup → USB Power Supply → Off** (supaya kamera tak tarik kuasa dari Pi)
3. Quality: **JPEG** (Fine / Extra fine) — bukan RAW+JPEG
4. **PC Remote Settings → Still Img. Save Dest. → PC+Camera** — *kalau menu ini ada pada firmware kamera.*
   Kalau tiada, gambar hanya masuk Pi (tak masuk SD). Pi tetap simpan 30 gambar terakhir sebagai backup.

---

## 3. Pasang di Raspberry Pi 5

### Cara A — Image SD siap flash (disyorkan)

Image dibina oleh GitHub Actions (Raspberry Pi OS Lite 64-bit + semua software dah dipasang,
tak perlu internet di venue).

**Bina image (sekali sahaja, atau bila ada update):**
1. Buka https://github.com/new → nama `johorstudio-pi5-tether` → **Private** → Create.
2. Di Mac:
   ```bash
   cd johorstudio-pi5-tether
   git init -b main && git add . && git commit -m "JohorStudio Tether"
   git remote add origin https://github.com/RafieRosliputra/johorstudio-pi5-tether.git
   git push -u origin main
   ```
3. GitHub → tab **Actions** → **Build Pi 5 image** → **Run workflow**. Tunggu ~30–60 minit.
4. Tab **Releases** → muat turun `johorstudio-tether-pi5-XXXXXXXX.img.xz`.

**Flash:**
1. Raspberry Pi Imager → Device: Raspberry Pi 5 → OS: **Use custom** → pilih fail `.img.xz` → pilih SD.
2. Bila Imager tanya *"apply OS customisation?"* → **NO**.
3. Selepas siap, cabut & cucuk semula SD ke Mac. Buka cakera **bootfs** → edit `jstether.txt`:
   ```
   WIFI_SSID=NamaRouter
   WIFI_PASSWORD=katalaluanwifi
   PI_PASSWORD=katalaluanbaru
   ```
   Boleh tambah `WIFI2_SSID` (contoh hotspot telefon) sebagai backup.
4. Eject, masukkan SD ke Pi, hidupkan. Boot pertama ~1–2 minit.
5. OLED tunjuk IP → sedia. SSH: `ssh jstether@jstether.local`

Nak tukar WiFi di venue lain? Cucuk SD ke Mac, edit `jstether.txt`, boot semula.
Kata laluan Pi dipadam sendiri dari fail selepas dipakai (supaya tak tertinggal dalam SD).

### Cara B — Pasang manual atas Raspberry Pi OS sedia ada

1. Guna **Raspberry Pi Imager** → Raspberry Pi OS Lite (64-bit).
   Dalam setting Imager: hostname `jstether`, hidupkan SSH, isi WiFi router anda.
2. Salin folder `pi/` ke Pi, kemudian:
   ```bash
   scp -r pi rafi@jstether.local:~/
   ssh rafi@jstether.local
   cd ~/pi && sudo bash install.sh
   ```
3. Semak:
   ```bash
   sudo systemctl status jstether
   sudo journalctl -u jstether -f      # log langsung
   sudo i2cdetect -y 1                 # OLED patut tunjuk 3c
   ```

Servis auto start bila Pi hidup. Tak perlu buat apa-apa lagi.

> Kalau rangkaian venue sekat Bonjour, set IP Mac secara manual:
> edit `/etc/systemd/system/jstether.service`, buka baris `JSTETHER_MAC=IP-MAC:47800`, kemudian
> `sudo systemctl daemon-reload && sudo systemctl restart jstether`.

---

## 4. Pasang app di Mac

Perlu Xcode Command Line Tools sekali sahaja: `xcode-select --install`

```bash
cd mac
bash build-app.sh
```

App **JohorStudio Tether** dipasang ke /Applications dan ikon kamera keluar di menu bar.

Kali pertama buka, macOS mungkin tanya:
- **Local Network** → Allow (wajib, supaya Pi boleh jumpa Mac)
- **Incoming connections / Firewall** → Allow
- **Akses Desktop** → OK

Dalam app:
- **Folder destinasi** — default `~/Desktop/LIVEFOLDER`. Tekan **Tukar…** untuk pilih folder lain, **Default** untuk kembali.
- Status **Pi**, **Kamera**, **Queue** (gambar tertunggak di Pi).
- **Gambar terkini** — klik untuk tunjuk dalam Finder.
- **Buka bila login** — app auto start bila Mac hidup.

Ikon menu bar:
- 📷 kamera biasa → Pi online
- 📷 dengan titik → menunggu Pi
- 📷 penuh (kelip) → gambar baru masuk

---

## 5. Aliran kerja di event

1. Hidupkan router → Mac sambung router → buka app (atau auto bila login).
2. Hidupkan Pi, cucuk kamera ke Pi.
3. OLED tunjuk `CAM ILCE-7RM2` dan nama Mac → sedia.
4. Tangkap gambar → masuk LIVEFOLDER dalam ~1–2 saat (bergantung WiFi dan saiz JPG).

---

## 6. Uji tanpa kamera

Uji app Mac sahaja (dari Mac sendiri):
```bash
curl -X POST --data-binary @test.jpg "http://localhost:47800/upload?name=TEST.JPG"
```

Uji Pi tanpa kamera:
```bash
sudo systemctl stop jstether
sudo JSTETHER_NO_CAMERA=1 python3 /opt/jstether/jstether.py
# terminal lain: salin JPG ke /var/lib/jstether/incoming/
```

---

## 7. Masalah biasa

| Masalah | Penyelesaian |
|---|---|
| OLED tulis `TIADA KAMERA` | Pastikan USB Connection = PC Remote; cabut-cucuk kabel; `gphoto2 --auto-detect` |
| OLED tulis `MENCARI MAC...` | App Mac belum buka / Local Network belum di-Allow / Pi & Mac lain rangkaian. Guna `JSTETHER_MAC` |
| `Q:` naik tapi tak turun | Mac terputus — gambar selamat di Pi, akan dihantar bila sambung |
| Gambar lambat | Letak router dekat; guna WiFi 5GHz; Mac sambung router guna LAN |
| Error `Could not claim the USB device` | Ada proses lain pegang kamera: `sudo pkill -f gvfs` lalu `sudo systemctl restart jstether` |

Fail di Pi: `/var/lib/jstether/{incoming,pending,sent}`
