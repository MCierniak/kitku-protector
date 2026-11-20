# Przełącznik klawiatury wbudowanej (KitkuProtector)

Aplikacja do blokowania i odblokowania wybranych klawiatur w laptopie jednym kliknięciem. Niezbędnik każdego *home-office* z kocim menagerem, którego stanowiskiem dowodzenia jest biurko a w szczególności ciepły i wygodny laptop.

Blokada pozostaje aktywna do ponownego kliknięcia skrótu albo do restartu komputera.

## Dla użytkowników

### 1. Pobieranie

| | |
| --- | --- |
| Instalator | [KitkuProtector-Setup-1.0.0.exe](<!-- TODO:link -->) |
| SHA-256 | `SUMA_SHA256_DO_UZUPEŁNIENIA` <!-- TODO: insert sha once build is ready --> |

### 2. (Opcjonalnie) Sprawdzenie pobranego pliku

Zanim uruchomisz instalator, sprawdź, czy plik nie został uszkodzony ani podmieniony:

* Linux shell

   <!-- TBD -->

* Windows Powershell

   ```powershell
   (Get-FileHash .\KitkuProtector-Setup-1.0.0.exe -Algorithm SHA256).Hash -eq '<SHA-256>'
   ```

* Windows CMD

   <!-- TBD -->

**Jeśli sumy się różnią, nie uruchamiaj instalatora.** Usuń plik i pobierz go ponownie.

### 3. Instalacja

<!-- TBD -->

### 4. Korzystanie z KitkuProtector

1. Kliknij ikonę **KitkuProtector** na pulpicie albo w menu Start.
   * W zależności od ustawień wybranych podczas instalacji, skrót może manipulować wszystkimi klawiaturami, wybranymi lub jedną konkretną. Można zmienić te ustawienia ponownie uruchamiając instalator.
2. Po kilku sekundach na dole ekranu pojawi się komunikat:
   * **Klawiatura zablokowana** (czerwony pasek) – wbudowana klawiatura nie reaguje,
   * **Klawiatura odblokowana** (zielony pasek) – wbudowana klawiatura znowu działa.

Komunikat znika sam po 3 sekundach albo po kliknięciu.

Dobrze wiedzieć:

* Korzystanie z KitkuProtector nie wymaga uprawnień administratora.
* Restart (Uruchom ponownie) zawsze odblokowuje klawiaturę.
* Klawiatura pozostaje wyłączona po zablokowaniu ekranu.
  * Jeżeli użytkownik nie ma dostępu do zewnętrznej klawiatury to w celu odblokowania ekranu należy uruchomić klawiaturę ekranową (Ułatwienia dostępu → Klawiatura ekranowa).

### 5. Odinstalowanie

**Ustawienia → Aplikacje → Zainstalowane aplikacje → KitkuProtector → Odinstaluj**
(albo Panel sterowania → Programy i funkcje).

Deinstalacja odblokowuje klawiaturę, jeśli była zablokowana, i usuwa wszystkie pliki, skróty oraz zadanie systemowe.

---

## Dla programistów

### Struktura projektu

<!-- TBD -->

### Budowanie instalatora

<!-- TBD: skrypt bash dla linuxa i ps1 dla windowsa budujący windowsowy plik exe instalatora i sha256 -->

Wynik trafia do `dist\`:

* `KitkuProtector-Setup-1.0.0.exe` – instalator,
* `KitkuProtector-Setup-1.0.0.exe.sha256` – suma SHA-256 w formacie `sha256sum`.

Każde budowanie daje plik o innej sumie, bo instalator zawiera znaczniki czasu. Sumę podawaj zawsze z tego samego builda, który publikujesz.

### Jak działą KitkuProtector

<!-- TBD -->

### Co robi instalator

<!-- TBD -->

### Bezpieczeństwo

<!-- TBD -->

### Wymagania środowiska

<!-- TBD -->

### Testowanie

<!-- TBD -->
