# Snakey: Yol Haritası

Durum: `[ ]` yapılacak · `[~]` devam ediyor · `[x]` bitti · `[?]` Yavuz'un kararı gerekli
Her görev: **kimlik, sorumlu agent, kabul kriteri.** Orkestratör bitirdiği görevi burada işaretler.

---

## Faz 0: Altyapı
- [x] **F0-1** git deposu, `origin` = freeloki/SnakeY, `develop` dalı üzerinde
- [x] **F0-2** `CLAUDE.md`, `.claude/agents/*`, `.claude/settings.json`, bu dosya, `docs/TESTING.md`
- [x] **F0-3** (Yavuz) `GODOT` ortam değişkenini ayarla, `claude` ile proje klasöründe ilk oturumu aç → bkz. TESTING.md
- [x] **F0-4** (Yavuz) `develop`'u push et. Jira ihtiyacı sonra değerlendirilecek, gerekirse GitHub Issues kullanılır.

## Faz 1: Ortak çekirdek (refactor, davranış değişmez)
Neden: üç script'te ~1500 satır kopya kod var. Sabitler elle senkron tutuluyor ve headless test yazmak imkânsız, çünkü mantık `Node2D` + çizim + UI ile iç içe.
- [x] **F1-1** `gdscript-dev`: `scripts/core/brain.gd` (`class_name SnakeBrain`, RefCounted). Q-tablosu, epsilon, taklit ağırlığı, `select_action`, `update_q`, `load/save`. Sabitler tek yerde.
  - Kabul: `ai_brain.json` formatı birebir aynı, mevcut kayıtla açılıyor.
- [x] **F1-2** `gdscript-dev`: `scripts/core/arena.gd`. Grid, yılan hareketi, çarpışma, yem spawn (aynalı dahil), faz/barikat, `step()`. Çizim ve input yok.
- [x] **F1-3** `gdscript-dev`: `scripts/core/preset_ai.gd`. `level_params`, `preset_decide`, `flood_fill_count`.
- [x] **F1-4** `gdscript-dev`: main / single_player / fast_train bu sınıfları kullanacak şekilde sadeleşir (sadece UI + çizim + input kalır).
- [x] **F1-5** `reviewer` + Yavuz manuel test: üç mod eskisi gibi oynanıyor.
- [x] **F1-6** Faz süreleri tutarsız: `main.gd` 5 sn / 10 sn, `single_player` ve `fast_train` 5 sn / 30 sn. Bu bilinçli mi? Refactor sırasında tek değere mi indirilecek?
  - Karar (Yavuz): Antrenman'daki 10 sn bilinçli, testler hızlı olsun diye kısa tutuldu. Süreler korundu, her mod süresini `SnakeArena`'ya parametre verir. Yayın öncesi Antrenman süresi gözden geçirilecek.

## Faz 2: Test altyapısı
- [x] **F2-1** `tester`: `tools/smoke_test.gd` + `tools/run_smoke.sh`. Tüm sahneleri headless yükler, ~60 kare çalıştırır, hata varsa exit 1.
- [x] **F2-2** `tester`: `tools/eval_ai.gd`. Beynin kopyasıyla, seed'li, N maç × seviye L simülasyonu (çizimsiz, gerçek zamandan bağımsız). Çıktı: `tools/out/eval_<tarih>.json` (kazanma %, ort. skor, ölüm nedeni dağılımı).
- [ ] **F2-3** `tester`: `tests/` altında core birim testleri (çarpışma, aynalı yem, Q güncelleme). Tercihen gdUnit4, yoksa düz script.
- [x] **F2-4** Baz ölçüm: mevcut beyinle seviye 1-5 eval sonucu ROADMAP'e not edilir.

## Faz 3: AI iyileştirme (ölçüm odaklı)
Sorun (F2-4 ölçümü): seviye 1-5'te kazanma %10-24; AI çoğunlukla duvara ve kendi gövdesine çarpıyor. Eski kuralda seviye tek galibiyetle geçildiği için `highest_cleared` beynin gücünü olduğundan yüksek gösteriyordu (F3-8).
- [~] **F3-1** `ai-trainer`: eğitimsiz beyinle "headless self-training" scripti (`tools/train_ai.gd`), parametre denemelerini dakikalar içinde yapmak için.
- [?] **F3-2** `ai-trainer`: flood-fill / kaçış alanı bitleri ile durum v2. **Mevcut Q-tablosunu sıfırlar.** Yedek + versiyon + Yavuz onayı.
- [ ] **F3-3** `ai-trainer`: ödül ve epsilon taraması, en iyi set eval ile seçilir.
- [ ] **F3-4** Seviye eğrisi kalibrasyonu: hazır rakip seviyeleri gerçekten kademeli zorlaşıyor mu (seviye L vs L+1 eval).
- [x] **F3-5** `ai-trainer`: hamle maskesi. Boş kare varken dolu kareye girilmez. Donmuş beyinle ölçüm: seviye 1-5 ~%12 → ~%68.
- [ ] **F3-6** `ai-trainer`: oyuncu hamlelerinden öğrenme. Antrenman'daki hamleler ödül/cezasıyla Q-tablosuna işlenir. Etkisi oyuncu yerine geçen botla ölçülür.
- [ ] **F3-7** `ai-trainer`: taklit azalması. Şu an her maçta azalıyor (1404 maçta etkisi ~0,0075 puan), Hızlı Antrenman maçları oyuncudan öğreneni söndürmemeli.
- [x] **F3-8** `gdscript-dev`: seviye geçme kuralı. 5 maçlık seride 3 galibiyet, berabere galibiyet sayılmaz. Mevcut `highest_cleared` korunur.

## Faz 4: Cila
- [ ] **F4-1** Görsel tema (renk paleti, yılan/yem çizimi, barikat animasyonu)
- [ ] **F4-2** Ses efektleri + müzik, ayarlarda aç/kapa
- [ ] **F4-3** AI "beyin" istatistik ekranı (oynanan maç, seviye, kazanma eğrisi)
- [ ] **F4-4** Uygulama ikonu, splash, Türkçe karakter düzeltmeleri (şu an "Coklu", "Cok Kolay" ASCII)

## Faz 5: Android yayın
- [?] **F5-1** Paket adı (örn. `com.yavuz.snakey`), oyunun mağaza adı
- [ ] **F5-2** `release`: Android export preset + Godot Android build template
- [ ] **F5-3** (Yavuz) keystore oluşturma (`release`'in verdiği komutla)
- [ ] **F5-4** `release`: ilk AAB, Play Console internal testing
- [ ] **F5-5** Gizlilik politikası, içerik derecelendirme, store listing metinleri

## Faz 6: Multiplayer
- [ ] **F6-1** `netcode`: `docs/multiplayer-design.md` (yerel/online, transport, otorite modeli, backend, maliyet)
- [?] **F6-2** Tasarım onayı
- [ ] **F6-3+** Uygulama (onaydan sonra alt görevlere bölünür)

## Faz 7: iOS
- [ ] Apple Developer hesabı (99 $/yıl), Mac/Xcode erişimi, iOS export

---

## Ölçüm günlüğü
| Tarih | Görev | Seviye | Maç | Kazanma % | Not |
|---|---|---|---|---|---|
| 2026-11-03 | F2-4 | 1 | 200 | 23.5 | Maskesiz baz, 1404 maçlık beyin, seed 1000 |
| 2026-11-03 | F2-4 | 2 | 200 | 11.5 | Maskesiz baz, 1404 maçlık beyin, seed 1000 |
| 2026-11-03 | F2-4 | 3 | 200 | 13.0 | Maskesiz baz, 1404 maçlık beyin, seed 1000 |
| 2026-11-03 | F2-4 | 4 | 200 | 10.0 | Maskesiz baz, 1404 maçlık beyin, seed 1000 |
| 2026-11-03 | F2-4 | 5 | 200 | 14.0 | Maskesiz baz, 1404 maçlık beyin, seed 1000 |
| 2026-11-03 | F3-5 | 1 | 200 | 64.5 | Maskeli, aynı 1404 maçlık beyin, seed 1000 |
| 2026-11-03 | F3-5 | 2 | 200 | 68.0 | Maskeli, aynı 1404 maçlık beyin, seed 1000 |
| 2026-11-03 | F3-5 | 3 | 200 | 66.5 | Maskeli, aynı 1404 maçlık beyin, seed 1000 |
| 2026-11-03 | F3-5 | 4 | 200 | 69.5 | Maskeli, aynı 1404 maçlık beyin, seed 1000 |
| 2026-11-03 | F3-5 | 5 | 200 | 62.5 | Maskeli, aynı 1404 maçlık beyin, seed 1000 |
| 2026-11-03 | F3-5 | 50 | 200 | 35.5 | Maskeli, aynı 1404 maçlık beyin, seed 1000 |
| 2026-11-03 | F3-5 | 90 | 200 | 11.0 | Maskeli, aynı 1404 maçlık beyin, seed 1000 |
| 2026-11-08 | F3-1 | 1 | 200 | 16.5 | Boş beyin, eğitimsiz (train_ai ölçümü, taklitsiz), seed 1000 |
| 2026-11-08 | F3-1 | 1 | 200 | 64.5 | Boş beyin + train_ai 3000 maç seviye 1, taklitsiz; 3 eğitim seed'i ort. (64.0 / 62.5 / 67.0), eval seed 1000 |
| 2026-11-08 | F3-1 | 2 | 200 | 64.7 | Aynı 3 beyin ort. (70.0 / 58.0 / 66.0), eval seed 1000 |
| 2026-11-08 | F3-1 | 3 | 200 | 65.0 | Aynı 3 beyin ort. (63.0 / 62.0 / 70.0), eval seed 1000 |
| 2026-11-08 | F3-1 | 4 | 200 | 65.3 | Aynı 3 beyin ort. (64.0 / 64.0 / 68.0), eval seed 1000 |
| 2026-11-08 | F3-1 | 5 | 200 | 63.5 | Aynı 3 beyin ort. (62.5 / 63.0 / 65.0), eval seed 1000 |
