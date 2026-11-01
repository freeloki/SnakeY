# Test rehberi

Üç test katmanı var. Agent'lar ilkini kendileri yapar, ikinci ve üçüncüsü senin işin.

## 1. Otomatik (agent'lar çalıştırır)
Godot'u pencere açmadan (headless) çalıştırarak:
- parse/import hataları,
- tüm sahnelerin açılıp açılmadığı (`tools/smoke_test.gd`, Faz 2),
- AI kazanma oranı ölçümü (`tools/eval_ai.gd`, Faz 2).

Sen bir şey yapmazsın. Agent'ın raporunda **GEÇTİ / KALDI** görürsün.

## 2. Editörde manuel test (senin işin, 2-5 dk)
Her görevin sonunda orkestratör sana kısa bir kontrol listesi verir. Örnek:
> - [ ] Menü → Hızlı Antrenman → 20 maç, Turbo → Başlat
> - [ ] Sayaç ilerliyor mu, Durdur çalışıyor mu?
> - [ ] Menüye dön → Tekli Oyun'da seviye bilgisi güncel mi?

Akış:
1. Claude değişikliği bir dalda yapar ve commit atar (örn. `feat/fast-train-fix`).
2. Godot editörü açıksa dosyalar diskte değiştiği için yeniden yüklemeyi sorar, **"Reload"** de.
3. **F5** ile oyunu çalıştır, listeyi uygula.
4. Claude'a sonucu yaz: "tamam, merge et" ya da "X'te şu oldu".
5. Beğenmediysen sorun yok: `git switch develop` ile eski hâline dönersin, hiçbir şey kaybolmaz.

> **Not:** AI beyni `%APPDATA%\Godot\app_userdata\snakey\ai_brain.json` içinde, git'in dışında durur. Riskli AI denemelerinden önce bu klasörü yedekle (ai-trainer zaten otomatik yedek alacak).

## 3. Telefonda test (Faz 5'ten itibaren)
- Telefonda Geliştirici Seçenekleri → USB hata ayıklama açık, USB ile bağla.
- Godot editörü sağ üstteki **Remote Deploy (Android ikonu)** ile tek tıkla yükler. Godot 4.6+ cihaz aynalama ile canlı izlenebilir.
- Dokunmatik kaydırma hissi, performans, ekran oranı burada test edilir.

## Kurulum (bir kerelik)
1. Godot'un **konsol** sürümünün yolunu ortam değişkenine yaz (PowerShell):
   ```powershell
   setx GODOT "C:\YOL\Godot_v4.7.2-stable_win64_console.exe"
   ```
   Yeni bir terminal aç ve doğrula: `"$GODOT" --version` (Git Bash) veya `& $env:GODOT --version` (PowerShell).
2. Proje klasöründe `claude` ile Claude Code'u başlat. `CLAUDE.md` ve agent'lar otomatik yüklenir. Doğrulamak için Claude'a "hangi subagent'lar tanımlı?" diye sor. (`/agents` sihirbazı yeni sürümlerde kaldırıldı; agent'lar doğrudan `.claude/agents/` dosyalarından okunur.)
3. İlk komut önerisi:
   > ROADMAP'teki Faz 1'e başla. F1-1'i gdscript-dev'e ver, tester ile doğrula, reviewer'a okut, ayrı dalda commit at ve bana manuel test listesini ver.
