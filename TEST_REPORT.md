# NEONPULSE — Laporan Pengujian

Tanggal pengujian: **11 November 2026**, zona waktu mesin `+0700`.

## Pembaruan UI bergaya btop

Versi UI terbaru lolos **13/13 pengujian dalam 27,720 detik**, exit status 0,
termasuk `bash -n monitor.sh`. Bukti terbaru berada di `tests/test-results.txt`.
Bagian laporan berikut mendokumentasikan baseline sebelumnya; angka benchmark
baseline tidak dianggap pengukuran ulang versi UI terbaru.

- Terminal >=100 kolom: empat panel, CPU/RAM berdampingan dan disk/proses berdampingan.
- Aksen cyan/magenta, tab aktif inverse-video, label warning tetap tersedia.
- Riwayat CPU/RAM dari sampel nyata, buffer dibatasi 120 sampel; belum ada data
  ditampilkan sebagai ruang kosong. Fixture deterministik riwayat ikut diuji.
- PTY lebar 100, 120, 160, 180 kolom: semua baris tepat selebar frame, tanpa overflow;
  frame lebar memakai 29 baris, maksimum 160 kolom. Fallback 76×30 tetap lulus.
- Navigasi, snapshot, append/rotasi, refresh, sinyal, dan cleanup lama tetap lulus.
- Pengukuran idle suite terbaru sekitar **8,66% satu core** selama 3 detik pada
  refresh 1 detik/log 2 detik; bukan benchmark jangka panjang.
- Capture teks dashboard terbaru ditinjau, tetapi rendering font/warna pada jendela
  terminal grafis pengguna masih perlu pemeriksaan manual.
- Assertion tambahan awal mengharapkan 30 baris untuk UI lebar; hasil sebenarnya
  29 baris yang muat dalam terminal 30 baris. Ekspektasi diperbaiki dan suite
  dijalankan ulang hingga seluruh pengujian lulus.

## 1. Diagnosis awal dan tindakan

`monitor.sh` awal berukuran 5589 byte dan memiliki izin executable `775`.
Baris pertama dimulai dengan `local pct=...`, tanpa `bar() {`. Terdapat penutup
`}` pada baris 10 tanpa pembuka. Akibatnya, `local` berada di scope global,
dan `bash -n monitor.sh` gagal dengan status **2** pada baris 10.
Bagian inisialisasi (shebang, konfigurasi, warna, variabel, log dan cleanup)
juga tidak ada. `monitor-backup.sh` identik byte-per-byte dengan skrip awal.

Perbaikan mempertahankan pendekatan dan nama fungsi CPU sampling, RAM, disk,
view proses, progress bar dan append log; menambahkan bootstrap yang hilang,
renderer dengan batas ukuran, bantuan, pengaturan terminal, rotasi dan pengujian.
`monitor-backup.sh` tetap **tidak diubah** sebagai bukti kondisi awal.

## 2. Lingkungan aktual

- Distribusi terdeteksi: **Linux Mint 22.3** (turunan Ubuntu).
- Kernel: **Linux 6.14.0-37-generic**, arsitektur x86_64.
- Bash: **5.2.21**.
- CPU logis terdeteksi: **8**; RAM sekitar **7683 MiB**.
- Filesystem terlapor saat uji: **8**, termasuk tmpfs dan EFI.
- Sesi eksekusi alat noninteraktif; uji interaktif menggunakan **PTY Linux nyata**.
- Tidak ada tmux atau ShellCheck terpasang; tidak dilakukan instalasi tambahan.
- Python 3 stdlib hanya digunakan sebagai driver pengujian, bukan runtime aplikasi.

## 3. Hasil final

Perintah yang benar-benar dieksekusi:

```bash
bash -n monitor.sh
python3 -I tests/test_monitor.py > tests/test-results.txt 2>&1
test -x monitor.sh
./monitor.sh --snapshot   # dua eksekusi terpisah untuk log runtime utama
```

Hasil suite final: **12 pengujian, 24,523 detik, OK, exit status 0**.
Pemeriksaan sintaks terakhir dan izin executable juga **lulus**.

| Pengujian | Metode/bukti | Hasil |
|---|---|---|
| Sintaks Bash | `bash -n monitor.sh` | Lulus, status 0 |
| Izin executable | `test -x`, `stat`: `-rwxrwxr-x`, 775 | Lulus |
| Cadangan asli | `cmp` awal identik; sintaks cadangan tetap gagal sesuai diagnosis | Lulus |
| Waktu, OS, hostname, kernel, uptime/load | Jalankan `--once`; cocokkan hostname/uname mesin | Lulus |
| CPU nyata | Rentang 0–100 dan valid sample; sampling `/proc/stat` nyata | Lulus |
| Rumus CPU | Fixture deterministik dua counter menghasilkan 60,0%; guest tidak dijumlah ulang | Lulus |
| RAM | Total cocok `/proc/meminfo`, used+available konsisten, persentase sesuai | Lulus |
| Disk | Jumlah entri cocok keluaran `df -hP`, tanpa pemotongan log | Lulus |
| Proses | Count positif, state R, tepat lima proses, urutan CPU menurun | Lulus |
| Append/timestamp | Dua eksekusi; byte lama tetap prefix, dua blok lengkap, pola timestamp valid | Lulus |
| Lokasi log | Eksekusi dari direktori kerja berbeda tetap menuju direktori skrip | Lulus |
| Tanpa ANSI pada log | Periksa byte ESC pada snapshot/log | Lulus |
| Rotasi | Sembilan snapshot, batas 4096 byte, dua arsip, blok utuh | Lulus |
| Append konkuren | Empat instance; empat pasangan batas awal/akhir tidak tersisip | Lulus |
| Kegagalan log | `logs` sengaja berupa berkas pada sandbox; status 1 dan pesan jelas | Lulus |
| Navigasi | PTY kirim `0/1/2/3/4/h/L/l/[/]/q` dan cek view tujuan | Lulus |
| Auto-refresh | PTY tanpa input; frame baru muncul | Lulus |
| Default interval | PTY refresh 2 detik, auto-log 10 detik, label dan blok baru diperiksa | Lulus |
| Resize | PTY 100×40 → 40×12 → 76×30, sinyal WINCH | Lulus |
| Terminal kecil | Pesan jelas; tombol log/quit tetap bekerja | Lulus |
| Batas layout | Frame minimum tepat 30 baris, setiap baris 75 kolom pada terminal 76 kolom | Lulus |
| Cleanup Q | Seluruh termios sebelum/sesudah identik; show cursor dan alternate-screen exit | Lulus |
| Cleanup sinyal | INT→130, TERM→143, HUP→129; termios/cursor dipulihkan | Lulus |
| ASCII/no-color | Garis ASCII; tidak ada escape warna SGR | Lulus |
| Validasi input | Config salah, opsi tidak dikenal, terminal noninteraktif | Lulus |
| Dependensi/data gagal | PATH kosong; mock ps/df gagal memberi status data tidak valid | Lulus |

### Riwayat kegagalan uji yang diselesaikan

Putaran suite pertama mempunyai satu assertion regex yang salah: `END SNAPSHOT`
diikuti `NEONPULSE SNAPSHOT` dianggap overlap. Empat blok log sebenarnya lengkap.
Assertion diperbaiki untuk memeriksa urutan marker start/end secara eksplisit.
Suite dijalankan ulang, lalu diperluas hingga 12 pengujian; **semuanya lulus**.
Tidak ada kegagalan suite yang belum diselesaikan pada putaran final.

## 4. Bukti visual dan performa

Frame hasil PTY ditinjau sebagai teks terminal; panel, meter, kolom, dan footer
tersusun utuh. Karakter non-ASCII pada judul internal yang tersanitasi menjadi
`???` ditemukan saat peninjauan awal dan diganti separator ASCII sebelum uji final.

Bukti tersimpan:

- `tests/test-results.txt`: keluaran suite final.
- `tests/dashboard.txt`: dashboard terminal 100×40.
- `tests/dashboard-minimum.txt`: dashboard terminal 76×30.
- `tests/terminal-session.ansi`: transkrip escape sequence interaksi terminal.
- `tests/snapshot.txt`: snapshot metrik nyata.
- `tests/idle-cpu.txt`: pengukuran penggunaan CPU saat menunggu input.
- `logs/monitor.log`: **dua snapshot runtime**, **2666 byte**, **tanpa ANSI**, ditulis
  oleh dua eksekusi aktual (bukan isi log buatan).

Pengukuran singkat:

- Sepuluh collector: 0,426 detik wall / 0,234 user / 0,186 sys
  (sekitar **42,6 ms/sampel**).
- Sepuluh renderer: 0,036 detik wall (sekitar **3,6 ms/frame**).
- Uji idle terakhir pada refresh 1 detik + log 2 detik: sekitar **10,33% dari satu
  core** selama 3 detik, mencakup Bash dan child yang sudah ditunggu menurut
  counter `/proc/PID/stat`. Bukan 10,33% seluruh delapan core, bukan benchmark
  jangka panjang; angka dapat berubah menurut beban dan jumlah proses/mount.

Validasi kontras teks/meter pada contoh latar `#10121c` memakai fungsi contrast
pada validator dataviz: cyan 10,33:1; magenta 7,58:1; purple 6,86:1; warning
12,19:1; critical 6,93:1; text 15,14:1; muted 7,10:1. Semua melebihi 4,5:1.
Warna status mempunyai label dan angka sebagai encoding tambahan. Latar terminal
pengguna tidak diubah sehingga hasil kontras aktual bergantung tema pengguna.

## 5. Pemetaan 12 persyaratan akademik

| No. | Persyaratan | Implementasi |
|---:|---|---|
| 1 | Tanggal dan waktu | timestamp setiap snapshot pada header/log |
| 2 | Hostname dan OS | hostname, `/etc/os-release` |
| 3 | Kernel Linux | `uname -sr` |
| 4 | Uptime dan load average | `/proc/uptime`, `/proc/loadavg` |
| 5 | Utilisasi CPU | delta `/proc/stat`, meter CPU |
| 6 | Utilisasi RAM | `/proc/meminfo`, MemAvailable, meter RAM |
| 7 | Disk lintas filesystem | `df -hP`, view berpaginasi; snapshot/log lengkap |
| 8 | Jumlah proses | total semua proses dan jumlah state R |
| 9 | Lima proses CPU tertinggi | `ps --sort=-pcpu`, tabel lima baris |
| 10 | Menu CPU/RAM/disk | tombol 1/2/3, plus dashboard/proses/bantuan |
| 11 | Log bertimestamp | `logs/monitor.log`, manual dan otomatis |
| 12 | Append pada monitoring ulang | `>>`, uji prefix dan append konkuren; rotasi terkonfigurasi |

## 6. Batasan dan pengujian manual tersisa

1. **Belum dijalankan pada jendela GNOME Terminal grafis milik pengguna.** PTY nyata
   menguji aplikasi/keyboard/resize/termios, tetapi tampilan font dan warna emulator
   grafis tetap perlu pemeriksaan manusia dan screenshot untuk laporan kampus.
2. **ShellCheck tidak dijalankan**, karena tidak tersedia. Validasi sintaks Bash
   dan pengujian runtime telah dilakukan; bukan pengganti klaim lint ShellCheck.
3. Pengujian langsung pada instalasi Debian/Ubuntu lain belum dilakukan; lingkungan
   aktual Linux Mint 22.3 berbasis Ubuntu, bukan instalasi Ubuntu bersih.
4. `df` sinkron dapat tersendat pada mount jaringan yang bermasalah. Tidak ada uji
   membuat mount macet, stress/destructive test, atau perubahan proses sistem.
5. CPU proses dari `ps` merupakan rata-rata umur proses; bukan interval real-time.
   Pembacaan resource berurutan bukan transaksi atomik. Ini dijelaskan dalam README.
6. SIGKILL tidak bisa ditangkap; cleanup untuk SIGINT/SIGTERM/SIGHUP dan Q sudah
   diuji. Tidak ada jaminan cleanup bila mesin mati atau terminal rusak paksa.
7. Batas retensi adalah batas berkas sebelum append: satu snapshot yang lebih
   besar dari limit tetap disimpan utuh, lalu dirotasi pada append berikutnya.

## 7. Reproduksi ringkas

```bash
cd ~/Documents/project-so
bash -n monitor.sh
python3 -I tests/test_monitor.py
./monitor.sh
# Coba tombol 0..4, H, L, [, ], ubah ukuran terminal, lalu Q.
```

Test harness hanya menutup proses aplikasi yang diluncurkannya sendiri dan
membersihkan direktori sandbox miliknya di dalam proyek. Tidak mengubah resource
sistem, mount, konfigurasi OS, ataupun mematikan proses milik pengguna lainnya.
