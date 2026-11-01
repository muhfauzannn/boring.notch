# Pengukuran performa — 2 November 2026

Pengukuran lokal pada Mac dengan 10 logical CPU dan RAM 16 GiB. Aplikasi utama
yang diperiksa adalah Boring Notch 2.7.3 (271), build **Debug di bawah Xcode/debugserver**.
Angka ini bukan hasil pengukuran aplikasi Release yang didistribusikan.

## Proses aplikasi yang sedang berjalan

`top` mengambil 16 sampel dengan interval 2 detik; sampel CPU pertama dibuang.
Kondisi aktif dan idle dikonfirmasi pengguna. Sampel aktif mencakup interaksi,
sehingga kedua sesi tidak merupakan eksperimen terkontrol untuk membandingkan fitur.

| Kondisi | CPU rata-rata aplikasi | Rentang CPU | CPU rata-rata helper |
| --- | ---: | ---: | ---: |
| Aktif, musik/kamera | 7,35% | 0–23,9% | 0,07% |
| Idle, musik dijeda, kamera dan panel ditutup | 9,82% | 7,2–12,4% | 0% |

CPU mengikuti konvensi `top`: 100% adalah satu logical CPU. Dengan 10 logical
CPU, 9,82% tersebut setara sekitar 0,98% dari kapasitas CPU keseluruhan.

Memori aplikasi berkisar sekitar 91–126 MiB dalam sesi aktif. `vmmap` melaporkan
physical footprint 124,7 MiB, peak 148,5 MiB, serta helper sekitar 9,1 MiB.
Footprint aplikasi saat sampel idle adalah 126,5 MiB. Total aplikasi dan helper
sekitar 135 MiB, kurang dari 1% RAM mesin ini. Memori tergolong ringan; CPU
berkelanjutan sekitar 10% satu core masih layak dikurangi untuk tampilan idle.
Sesi singkat ini tidak menguji kebocoran memori jangka panjang.

## Perubahan

- Mata idle menjadwalkan frame 60 fps hanya pada segmen keyframe yang bergerak,
  beserta endpoint-nya. Pose diam menunggu gerakan berikutnya. Jadwal turun dari
  720 menjadi 193 frame per 12 detik. Pause untuk layar tidur, sesi tidak aktif,
  view tersembunyi, dan Reduce Motion tetap berlaku.
- Timeline slider berhenti saat musik dijeda atau playback rate nol; sebelumnya
  interval `nil` justru mengizinkan pembaruan mengikuti refresh layar.
- Timeline lirik berhenti saat dijeda atau tanpa lirik tersinkron.
- Timer visualizer diinvalidasi ketika NSView dilepas atau dihancurkan.

## Uji komponen mata

Harness SwiftUI terpisah, kompilasi `swiftc -O`, menggunakan Canvas dan keyframe
aplikasi yang sama dalam jendela 116 × 32 pt. Masing-masing versi mendapat
warmup 2 detik dan pengukuran 24 detik. CPU diukur memakai selisih user + system
CPU time proses (`getrusage`) dibagi waktu aktual. Aplikasi utama tidak dihentikan.

| Komponen mata | CPU rata-rata | CPU time | Pembaruan clock |
| --- | ---: | ---: | ---: |
| Clock lama | 4,71% | 1,130 s | 1.440 |
| Jadwal baru | 0,85% | 0,204 s | 378 |

Pada satu pasangan pengujian ini, CPU komponen mata berkurang sekitar 82%.
Hasil tersebut **bukan** penurunan terukur CPU seluruh aplikasi. Proses aplikasi
yang sedang berjalan masih memakai build lama; pengukuran penuh setelah relaunch
build baru belum dilakukan. Aplikasi Release juga belum diprofilkan.

## Validasi

- Build Xcode Debug dan Release berhasil.
- Jadwal selalu maju, resume langsung pada waktu saat ini, loop berulang, dan
  jeda panjang hanya terjadi ketika semua nilai keyframe konstan.
- Segmen gerakan tetap dijadwalkan maksimal sekitar 16,7 ms antarframe.
- Pembersihan timer saat deallocation dan dismantle NSView diperiksa.
- Render pose sebelum/sesudah identik berdasarkan SHA-256. Bentuk mata dan
  keyframe tidak diubah.
- `git diff --check` lulus.

Artefak pengukuran sesi ini tersimpan di `/tmp/boring-notch-top-baseline.txt`,
`/tmp/boring-notch-top-idle.txt`, `/tmp/boring-notch-vmmap.txt`,
`/tmp/boring-notch-idle-sample.txt`, dan `/tmp/idle-clock-bench-{original,optimized}.txt`.
Harness pemeriksaan dan benchmark: `/tmp/IdlePerformanceChecks.swift` dan
`/tmp/IdleClockBench.swift`. Artefak `/tmp` bersifat sementara.
