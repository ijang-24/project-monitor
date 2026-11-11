# NEONPULSE

**Cyberpunk Linux System Monitor — proyek praktikum Sistem Operasi, Bash murni.**

Dashboard terminal dengan meter neon cyan/magenta, peringatan kuning/merah,
filesystem berpaginasi, lima proses teratas, dan snapshot log bertimestamp.
Tidak membutuhkan root, tidak mengubah atau menghentikan proses sistem.

## Instalasi dan menjalankan

Ubuntu/Debian (termasuk Linux Mint). Bash minimal versi 4, direkomendasikan Bash 5.
Umumnya semua utilitas berikut sudah terpasang. Jika belum, instal paketnya sendiri:

```bash
sudo apt update
sudo apt install bash coreutils procps util-linux gawk hostname
cd ~/Documents/project-so
chmod +x monitor.sh
bash -n monitor.sh
./monitor.sh
```

Terminal minimum **76 kolom × 30 baris**, rekomendasi **100 × 40**, font monospace
berdukungan Unicode dan latar gelap. Tidak perlu `sudo` saat menjalankan monitor.
Warna memakai ANSI truecolor; tampilan bergantung tema dan dukungan terminal.

```bash
./monitor.sh --help
./monitor.sh --once                 # satu sampel teks tanpa menulis log
./monitor.sh --snapshot             # satu sampel teks + append log
./monitor.sh --ascii --no-color     # kompatibilitas terminal sederhana
NO_COLOR=1 ./monitor.sh             # tanpa warna, meter tetap terbaca
```

Pemanggilan dari direktori lain tetap menulis log relatif terhadap lokasi skrip,
bukan direktori kerja pengguna. Jalankan langsung berkas asli, bukan symlink lintas direktori.
CPU dipriming selama 0,2 detik sebelum snapshot pertama agar bukan angka sejak boot.

## Keyboard

| Tombol | Aksi |
|---|---|
| `0` | Dashboard utama |
| `1` | CPU, model prosesor, load dan proses teratas |
| `2` | RAM dan swap |
| `3` | Seluruh filesystem melalui paginasi |
| `4` | Jumlah proses dan lima konsumen CPU tertinggi |
| `L` / `l` | Simpan snapshot terakhir yang sedang ditampilkan |
| `H` / `h` | Bantuan dan definisi metrik |
| `[` / `]` | Halaman filesystem sebelumnya / berikutnya |
| `Q` / `q` | Keluar dan pulihkan terminal |

Menu tetap responsif saat menunggu sampel berikutnya; polling keyboard 150 ms.
Refresh default 2 detik. Sampling `ps`/`df` bersifat sinkron: filesystem jaringan
yang macet dapat memperlambat refresh dan respons tombol. Tidak ada loop busy-wait.
Ukuran terminal dibaca ulang ketika menerima `SIGWINCH`. Di bawah ukuran minimum,
monitor menampilkan pemberitahuan; logging dan tombol keluar tetap aktif.

## Metrik dan akurasi

- **Tanggal/waktu:** waktu lokal sistem beserta offset zona waktu, setiap snapshot.
- **Identitas:** `hostname`, `uname -sr`, `uname -m`, `/etc/os-release` dibaca sebagai
  data, tidak dieksekusi sebagai shell. Pada mesin pengujian OS aktual **Linux Mint
  22.3**, turunan Ubuntu; nama OS tidak di-hardcode menjadi Ubuntu.
- **CPU:** dua sampel `/proc/stat` berturutan.
  `100 × (delta_total - delta_idle) / delta_total`, ditampilkan satu desimal.
  Total mencakup user, nice, system, idle, iowait, irq, softirq, steal.
  Idle mencakup iowait; guest/guest_nice tidak dijumlah ulang. Nilai merupakan
  pemakaian agregat seluruh CPU logis, skala 0–100%, bukan per-core.
- **RAM:** `/proc/meminfo`; used = MemTotal − MemAvailable. Cache yang dapat
  direklamasi tidak seluruhnya dianggap terpakai. Fallback kernel lama memakai
  MemFree + Buffers + Cached + SReclaimable − Shmem. Ukuran MiB = KiB / 1024.
- **Swap:** SwapTotal − SwapFree; tidak ada swap adalah kondisi normal.
- **Disk:** satu `df -hP` per snapshot, seluruh entri yang dilaporkan `df`, termasuk
  tmpfs, tidak hanya `/`. Paginasi mencegah pemotongan daftar secara permanen.
  Snapshot teks dan log selalu memuat seluruh entri. Meter ringkasan memakai `/`.
  Ini adalah **kapasitas filesystem**, bukan bandwidth atau kesibukan I/O disk.
  `df` tanpa `-a` secara normal mengabaikan pseudo-filesystem yang tidak menyediakan
  statistik kapasitas dan mount duplikat tertentu.
- **Proses:** `ps -eo pid,stat,pcpu,pmem,comm --sort=-pcpu`, lima tertinggi.
  TOTAL berarti semua proses, RUNNING berarti state `R` pada saat sampling.
  `%CPU` dari `ps` adalah rata-rata sepanjang umur proses, **bukan** delta 2 detik;
  dapat melebihi 100% untuk proses multithread. Proses monitoring sendiri termasuk.
- **Uptime/load:** `/proc/uptime` dan `/proc/loadavg` (1/5/15 menit).

Angka CPU/RAM/disk berasal dari sistem nyata, tanpa nilai acak. Pengumpulan
berurutan bukan snapshot atomik, sehingga pembandingan dengan `free`/`ps` sesaat
kemudian dapat berbeda. Kegagalan pembacaan memiliki flag validitas di snapshot;
UI memberi pemberitahuan data tidak lengkap, bukan mengklaim nol sebagai sukses.

## Logging dan retensi

Lokasi: **`logs/monitor.log`**. Snapshot dibuat saat aplikasi mulai, otomatis setiap
10 detik, dan saat `L` ditekan. Setiap blok memiliki timestamp, identitas OS/kernel,
uptime/load, CPU, RAM/available/swap, seluruh disk, jumlah proses, dan top five.
Tanpa ANSI. Berkas memakai append `>>`, tidak dikosongkan pada pemanggilan ulang.

Default rotasi: **1 MiB per berkas**, **3 arsip** (`monitor.log.1` sampai `.3`).
Sebelum append yang melampaui batas, berkas lama digeser; `.1` adalah arsip terbaru.
`flock` menyerialkan append/rotasi antardua instance, lock menunggu maksimal 2 detik.
Arsip tertua akhirnya diganti sesuai retensi; ini disengaja, bukan hilangnya log
akibat mode overwrite. Snapshot yang sendirian lebih besar dari batas tetap ditulis
utuh dan dirotasi pada append berikutnya: batas efektif adalah maksimum antara
batas konfigurasi dan ukuran satu snapshot, bukan batas byte keras.

Jika log tidak bisa dibuat/ditulis, dashboard tetap berjalan dengan pemberitahuan.
`--snapshot` mengembalikan status nonnol saat penulisan gagal. `--once` tidak perlu
akses tulis. `logs/.monitor.lock` merupakan berkas koordinasi runtime, boleh dibiarkan.

```bash
# Periksa hasil tanpa escape warna
less logs/monitor.log
# Uji append manual; jumlah blok bertambah dua selama belum memicu rotasi
./monitor.sh --snapshot
./monitor.sh --snapshot
grep -c '^=== NEONPULSE SNAPSHOT' logs/monitor.log
```

### Konfigurasi variabel lingkungan

| Variabel | Default | Rentang / arti |
|---|---:|---|
| `NEONPULSE_REFRESH` | `2` | 1–10 detik |
| `NEONPULSE_LOG_INTERVAL` | `10` | 1–86400 detik |
| `NEONPULSE_WARN` | `70` | 1–99 persen |
| `NEONPULSE_CRIT` | `90` | 2–100 persen, harus > WARN |
| `NEONPULSE_LOG_MAX_BYTES` | `1048576` | 4096–1073741824 byte |
| `NEONPULSE_LOG_KEEP` | `3` | 1–10 arsip |
| `NEONPULSE_ASCII` | `0` | 0 Unicode / 1 ASCII |
| `NO_COLOR` | tidak disetel | jika ada, warna dinonaktifkan |

```bash
NEONPULSE_REFRESH=1 NEONPULSE_LOG_INTERVAL=30 \
NEONPULSE_WARN=75 NEONPULSE_CRIT=92 ./monitor.sh
```

Peringatan selalu memiliki label `! WASPADA` / `!! KRITIS`, bukan hanya warna.
Kontras palet diuji terhadap contoh latar gelap `#10121c`; latar terminal pengguna
sengaja tidak diubah. `--no-color` tersedia jika tema terminal tidak sesuai.
Teks eksternal dibersihkan menjadi ASCII untuk mencegah escape injection dan
ketidakselarasan lebar Unicode; karakter non-ASCII diganti `?`, teks UI tetap Unicode.
Mount/path panjang dapat dipendekkan di UI, tetapi tersedia utuh di snapshot/log
(hingga 4096 karakter per baris; nama non-ASCII tetap disanitasi).

## Arsitektur

1. **Bootstrap:** parse argumen, validasi konfigurasi dan perintah, identitas sistem.
2. **Collector:** `cpu_sample`, `mem_values`, `root_values`, `process_values` dipanggil
   `collect_metrics`; hasil disimpan di variabel/array Bash dan digunakan bersama UI/log.
3. **Renderer:** `row`, `border`, `bar`, dan fungsi view. Frame dibangun dahulu lalu
   dicetak sekaligus; lebar dibatasi dan tidak menghapus layar penuh setiap refresh.
4. **Event loop:** jadwal refresh/log terpisah dari `read -t 0.15`, sehingga navigasi
   tidak memicu sampling CPU berlebihan. Ukuran memakai `stty size`.
5. **Logger:** `snapshot_text` menghasilkan teks netral; `write_log` menangani lock,
   append, rotasi, serta error I/O.
6. **Lifecycle:** trap EXIT/INT/TERM/HUP memulihkan pengaturan `stty`, cursor dan
   alternate screen. `SIGKILL` atau terminal yang putus paksa tidak dapat dijamin
   cleanup oleh program apa pun; jika perlu jalankan `stty sane` dan `reset`.

Dependensi runtime: Bash, coreutils (`date`, `sleep`, `mkdir`, `mv`, `wc`), procps
(`ps`), util-linux (`flock`, `stty` tersedia dari coreutils pada Ubuntu), `df`,
`hostname`, `uname`, `awk` (divalidasi untuk kompatibilitas lingkungan proyek).
Python **hanya untuk test harness opsional**, bukan implementasi aplikasi.

## Pengujian

```bash
cd ~/Documents/project-so
bash -n monitor.sh
test -x monitor.sh && printf 'Executable OK\n'
./monitor.sh --once
python3 -I tests/test_monitor.py
```

Suite memakai pustaka standar Python dan PTY Linux: aplikasi Bash yang sesungguhnya
dijalankan, tombol dikirim, ukuran diubah, terminal state dibandingkan sebelum/sesudah.
Data uji rotasi disimpan di direktori sementara **di dalam `tests/`**, lalu dibersihkan;
log runtime utama tidak dihapus. Tidak memerlukan instalasi Python package.

Bukti: `tests/test-results.txt`, `tests/dashboard.txt`, `tests/dashboard-minimum.txt`,
`tests/terminal-session.ansi`, `tests/snapshot.txt`, `tests/idle-cpu.txt`.
Laporan lengkap: [TEST_REPORT.md](TEST_REPORT.md).
Cadangan asli `monitor-backup.sh` sengaja tetap utuh dan masih mengandung error awal;
jalankan `monitor.sh`, bukan cadangan tersebut.

### Pemeriksaan manual sebelum demonstrasi

1. Jalankan pada GNOME Terminal/terminal ThinkPad dengan ukuran >=100×40.
2. Coba seluruh menu, lihat meter diperbarui saat beban sistem berubah secara alami.
3. Tekan `L`; periksa timestamp baru di log. Tunggu >=10 detik untuk auto-log default.
4. Perkecil terminal, perbesar lagi, lalu `Q`; pastikan echo dan cursor kembali.
5. Ambil screenshot untuk laporan; PTY menguji logika terminal tetapi bukan rendering
   font/warna emulator terminal grafis pengguna.

## Outline laporan praktikum 1–2 halaman

**Halaman 1**
- Judul, identitas, tujuan: observasi resource Linux menggunakan Bash.
- Lingkungan aktual: distribusi, versi kernel, ThinkPad, Bash; bukan spesifikasi asumsi.
- Metode: diagram collector → renderer/logger, rumus CPU delta, RAM available,
  `df` dan `ps`; jelaskan perbedaan CPU agregat vs `%CPU` rata-rata umur proses.
- Screenshot dashboard utama dan penjelasan menu singkat.

**Halaman 2**
- Tabel pemenuhan 12 persyaratan akademik dan sumber datanya.
- Potongan log bertimestamp yang menunjukkan append dari dua snapshot.
- Tabel uji: sintaks, metrik, menu, refresh, log, retensi, resize, cleanup.
- Analisis singkat: cache RAM, load average vs CPU%, tmpfs vs disk fisik.
- Batasan (sampling berurutan, `df` sinkron, emulator grafis belum diuji otomatis),
  kesimpulan, referensi `man bash`, `man proc`, `man ps`, `man df`.
