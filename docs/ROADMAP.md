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
- [ ] **F2-1** `tester`: `tools/smoke_test.gd`. Tüm sahneleri headless yükler, ~60 kare çalıştırır, hata varsa exit 1.
- [ ] **F2-2** `tester`: `tools/eval_ai.gd`. Beynin kopyasıyla, seed'li, N maç × seviye L simülasyonu (çizimsiz, gerçek zamandan bağımsız). Çıktı: `tools/out/eval_<tarih>.json` (kazanma %, ort. skor, ölüm nedeni dağılımı).
- [ ] **F2-3** `tester`: `tests/` altında core birim testleri (çarpışma, aynalı yem, Q güncelleme). Tercihen gdUnit4, yoksa düz script.
- [ ] **F2-4** Baz ölçüm: mevcut beyinle seviye 1-5 eval sonucu ROADMAP'e not edilir.

## Faz 3: AI iyileştirme (ölçüm odaklı)
Sorun: 167+ maçta seviye 2 geçilemiyor.
- [ ] **F3-1** `ai-trainer`: eğitimsiz beyinle "headless self-training" scripti (`tools/train_ai.gd`), parametre denemelerini dakikalar içinde yapmak için.
- [?] **F3-2** `ai-trainer`: flood-fill / kaçış alanı bitleri ile durum v2. **Mevcut Q-tablosunu sıfırlar.** Yedek + versiyon + Yavuz onayı.
- [ ] **F3-3** `ai-trainer`: ödül ve epsilon taraması, en iyi set eval ile seçilir.
- [ ] **F3-4** Seviye eğrisi kalibrasyonu: hazır rakip seviyeleri gerçekten kademeli zorlaşıyor mu (seviye L vs L+1 eval).

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
| | | | | | |
