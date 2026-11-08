# Snakey: Claude Code proje rehberi

Bu dosyayı her oturum ve her alt agent okur. Kısa ve güncel tutun.

## Proje
- 2D yılan oyunu, mobil (önce Android, sonra iOS). Konsept: **"Yılan Antrenörü"**. Oyuncu bir AI yılanı eğitir, eğitilen AI hazır rakiplere karşı merdiven tırmanır.
- Motor: **Godot 4.7**, dil **GDScript**. Renderer: Mobile. Portre 480x736.
- Geliştirici (Yavuz) Godot'ta yeni, Flutter/Dart geçmişi var. Açıklamalar Türkçe, kod ve yorumlar İngilizce.

## Yapı
| Dosya | Görev |
|---|---|
| `scenes/menu.tscn` + `scripts/menu.gd` | Ana menü (giriş sahnesi) |
| `scenes/main.tscn` + `scripts/main.gd` | **Antrenman**: oyuncu (alt) vs AI (üst), taklit öğrenme verisi toplar |
| `scenes/single_player.tscn` + `scripts/single_player.gd` | **Tekli Oyun**: eğitilen AI vs 1-100 seviye hazır rakip, kullanıcı izler |
| `scenes/fast_train.tscn` + `scripts/fast_train.gd` | **Hızlı Antrenman**: AI takıldığı seviyeye karşı otomatik çok maç (Turbo) |
| `scripts/core/brain.gd` | `SnakeBrain`: Q-tablosu, öğrenme ve ödül sabitleri, taklit modeli, beyin kaydet/yükle |
| `scripts/core/arena.gd` | `SnakeArena`: grid, hareket, çarpışma, yem, faz, durum kodlaması. Çizim ve input yok |
| `scripts/core/preset_ai.gd` | `PresetAI`: seviye parametreleri, hazır rakip kararı, flood-fill, merdiven kaydı |
| `scripts/core/ladder_series.gd` | `LadderSeries`: merdiven kuralı, 5 maçlık seride 3 galibiyet seviyeyi geçer (berabere = galibiyet değil). Sadece bellekte, kayıt formatı değişmez |
| `tools/golden_trace.gd` + `tools/run_golden.sh` | Davranış koruma testi: aynı seed ile üç modun kayıt ve mesaj hash'ini karşılaştırır |
| `docs/ROADMAP.md` | Faz planı ve görev listesi (tek doğruluk kaynağı) |
| `docs/TESTING.md` | Test katmanları ve komutlar |

## Kalıcı veri (`user://`, Windows'ta `%APPDATA%\Godot\app_userdata\snakey\`)
| Dosya | Yazan | Okuyan |
|---|---|---|
| `ai_brain.json` (q_table, games_played; epsilon ve imitation_weight dosyada yok, yüklemede games_played'den hesaplanır) | main, single_player, fast_train | hepsi |
| `player_model.json` | **sadece** main | single_player, fast_train (salt okunur) |
| `ladder_progress.json` (highest_cleared) | single_player, fast_train | hepsi |
| `snakey_save.json` | main | main |

**Format değişikliği = kullanıcının eğitimi kaybolur.** `ai_brain.json` şemasını veya durum kodlamasını (`SnakeArena.compute_state`) değiştiren her iş önce Yavuz'a sorulur ve bir sürüm/migration planı içerir.

## Kritik kurallar
1. **Paylaşılan beyin:** Üç mod aynı Q-tablosunu kullanır. Öğrenme sabitleri ve mantığı yalnızca `scripts/core/` altındadır, sahne script'lerine kopyalanmaz. Sahne script'lerinde yalnızca UI, çizim, input ve maç akışı bulunur.
2. Grid: 15 sütun x 23 satır, satır 11 barikat. Antrenman'da üst yarı AI, alt yarı oyuncu. Tekli Oyun ve Hızlı Antrenman'da üst yarı hazır rakip, alt yarı eğitilen AI.
3. Godot 4.7 API'si kullan (Godot 3 sözdizimi yok: `yield`, `onready var`, `export var` yasak; `await`, `@onready`, `@export` kullan). Tipli GDScript tercih et.
4. `.tscn` dosyalarını elle düzenlerken `uid` ve `ExtResource` id'lerini bozma. Yeni script'ler için `.gd.uid` dosyasını Godot üretir, sen uydurma.
5. Keystore, şifre, `export_credentials.cfg` asla commit edilmez.

## Komutlar
Godot yolu `GODOT` ortam değişkeninde (örn. `C:/Godot/Godot_v4.7.2-stable_win64_console.exe`). Konsol (`_console.exe`) sürümünü kullan, yoksa çıktı görünmez.
```bash
"$GODOT" --headless --path . --import                       # import / parse kontrolü
"$GODOT" --headless --path . --check-only --script res://scripts/main.gd   # tek script sözdizimi
bash tools/run_golden.sh <fixture_klasörü> <çıktı> [referans]   # davranış koruma testi, user:// geçici klasöre yönlenir
bash tools/run_smoke.sh                                     # tüm sahneleri yükler, user:// geçici klasöre yönlenir
"$GODOT" --headless --path . --script res://tools/eval_ai.gd -- --level=2 --matches=200   # AI değerlendirme, salt okunur; çıktı tools/out/
```

## Git akışı
- Uzak depo: `origin` = https://github.com/freeloki/SnakeY (public, MIT).
- **`develop`**: günlük geliştirme dalı, her zaman çalışır durumda. **`main`**: yalnızca sürüm/yayın (Play Store'a giden hâl).
- Her görev `develop`'tan açılan ayrı dal: `feat/...`, `fix/...`, `refactor/...`, `ai/...`.
- Commit mesajı Türkçe, kısa başlık + gerekirse açıklama. Görev kimliğini ekle (örn. `[F1-2]`).
- Commit öncesi: tester agent'ın headless kontrolleri geçmeli. Görev dalı `develop`'a **Yavuz editörde test edip onay verdikten sonra** merge edilir. `develop`'tan `main`'e merge sadece sürüm çıkarken yapılır.
- `git push`, dal silme, `reset --hard` gibi geri alınamaz işler için önce sor. Depo public, bu yüzden gizli bilgi asla commit edilmez.

## Orkestrasyon (ana oturumun rolü)
Ana oturum orkestratördür: `docs/ROADMAP.md`'den görevi alır, uygun agent'a verir, sonucu tester'a doğrulatır, reviewer'a okutur, commit atar ve ROADMAP'te görevi işaretler.

Agent'lar (`.claude/agents/`): `gdscript-dev`, `ai-trainer`, `tester`, `reviewer`, `release`, `netcode`.

Tipik döngü: **plan, dev/ai-trainer, tester, reviewer, commit, Yavuz'un manuel testi, merge.**
