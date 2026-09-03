# Windows WOL Remote Power Setup

Script PowerShell untuk menyiapkan PC Windows agar dapat dikontrol melalui panel Wake-on-LAN.

Fitur yang disiapkan:

- Membuat atau memperbarui akun lokal Administrator.
- Memberikan izin `Force shutdown from a remote system`.
- Mengaktifkan layanan Windows yang diperlukan.
- Membuka akses SMB dan RPC hanya dari jaringan lokal.
- Mendukung aksi Turn Off dan Restart dari panel.
- Tidak mengganti user Windows yang sedang login.

## Menjalankan Setup

Buka PowerShell pada PC client, lalu jalankan:

```powershell
$scriptUrl = 'https://raw.githubusercontent.com/Abdurozzaq/ScriptAllowWOL/refs/heads/main/setup-wol.ps1'
$scriptPath = Join-Path $env:TEMP 'setup-wol.ps1'
Invoke-WebRequest -Uri $scriptUrl -OutFile $scriptPath
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Username 'YOUR_ADMIN_USERNAME' -Password 'YOUR_ADMIN_PASSWORD'
```

Ganti:

- `YOUR_ADMIN_USERNAME` dengan username Administrator yang akan dibuat.
- `YOUR_ADMIN_PASSWORD` dengan password yang akan digunakan.

Script akan meminta konfirmasi UAC Administrator. Restart PC client setelah setup selesai.

Script dapat dijalankan ulang. Jika username sudah ada, password dan konfigurasinya akan diperbarui.

## Konfigurasi Server WOL

Gunakan username dan password yang sama pada file `.env` server:

```env
REMOTE_SHUTDOWN_USER=YOUR_ADMIN_USERNAME
REMOTE_SHUTDOWN_PASSWORD=YOUR_ADMIN_PASSWORD
REMOTE_SHUTDOWN_TIMEOUT_MS=60000
```

## Pengujian Manual

Jalankan dari PowerShell pada server:

```powershell
Test-NetConnection CLIENT_IP -Port 445
net use \\CLIENT_IP\IPC$ /user:YOUR_ADMIN_USERNAME *
shutdown.exe /m \\CLIENT_IP /r /f /t 0
```

`TcpTestSucceeded` harus bernilai `True` dan perintah `net use` harus berhasil.

## Troubleshooting

- **Error 53:** client belum online atau SMB/RPC diblokir firewall.
- **Error 5:** username/password salah atau akun belum memiliki izin.
- **Command timed out:** IP tidak dapat dijangkau atau Windows belum selesai boot.
- **Turn On tidak bekerja:** aktifkan Wake-on-LAN pada BIOS/UEFI dan network adapter.

## Keamanan

Password diberikan melalui parameter CLI sehingga dapat tersimpan dalam riwayat PowerShell. Gunakan password yang kuat dan jangan membagikan command yang sudah berisi password asli.
