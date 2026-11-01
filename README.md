# Overleaf self-hosted installer

Εγκατάσταση του **Overleaf Community Edition** σε δικό σου server με **μία εντολή**, έτοιμο για
πραγματικές εργασίες: πλήρες TeX Live, ελληνικά, XeLaTeX/LuaLaTeX, γραμματοσειρές Microsoft και
nginx μπροστά.

*English summary at the end.*

## Τι κάνει

| Βήμα | Λεπτομέρειες |
|---|---|
| Έλεγχος μηχανήματος | Ubuntu/Debian, x86_64, RAM, ελεύθερος χώρος, IP |
| Εξαρτήσεις | Docker, Docker Compose v2, git (από τα πακέτα της διανομής) |
| Overleaf | Το επίσημο [overleaf/toolkit](https://github.com/overleaf/toolkit) με Overleaf, MongoDB, Redis |
| MongoDB σε νέο kernel | Σε kernel ≥ 6.19 η MongoDB 8 δεν ξεκινά ([SERVER-121912](https://jira.mongodb.org/browse/SERVER-121912)). Προστίθεται αυτόματα η διόρθωση `GLIBC_TUNABLES=glibc.pthread.rseq=1` |
| Πλήρες TeX Live | `scheme-full` (~8 GB), ξαναχτίσιμο formats, γραμματοσειρές TeX Live ορατές στο XeLaTeX |
| Γραμματοσειρές Microsoft | Times New Roman, Arial, Courier New κ.λπ. (προαιρετικά, μετά από αποδοχή της άδειας EULA) |
| Μόνιμο image | Το αποτέλεσμα αποθηκεύεται ως `sharelatex/sharelatex:<έκδοση>-with-texlive-full` ώστε να μη χάνεται σε restart |
| nginx | Χρησιμοποιεί το υπάρχον nginx (και custom builds), αλλιώς εγκαθιστά της διανομής. Ελέγχει τη ρύθμιση και την επαναφέρει αν αποτύχει |
| Έλεγχος | Δοκιμαστικό compile με XeLaTeX, ελληνικά, `mathspec`, `fncychap`, `biblatex`, `multirow` |

Το script μπορεί να ξανατρέξει με ασφάλεια: ό,τι υπάρχει ήδη, το αναγνωρίζει και το προσπερνά.

## Απαιτήσεις

- Ubuntu 22.04+ ή Debian 12+, **x86_64** (τα επίσημα images του Overleaf δεν υπάρχουν για ARM / Raspberry Pi)
- 4 GB RAM ή περισσότερα (προτείνονται 8+)
- ~25 GB ελεύθερος χώρος (με το πλήρες TeX Live)
- Πρόσβαση `sudo` και σύνδεση στο internet

## Εγκατάσταση

```bash
git clone https://github.com/<owner>/<repo>.git
cd <repo>
sudo ./install.sh
```

ή κατευθείαν:

```bash
curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/install.sh | sudo bash
```

Η εγκατάσταση του TeX Live κρατά συνήθως 30–60 λεπτά. Αν τρέχεις μέσω SSH, καλό είναι να
χρησιμοποιήσεις `tmux` ή `screen`, ώστε να μη διακοπεί αν κοπεί η σύνδεση.

Μόλις τελειώσει:

1. Άνοιξε `http://<IP του server>/launchpad` και φτιάξε τον πρώτο λογαριασμό διαχειριστή.
2. Πρόσθεσε άλλους χρήστες από **Admin → Manage Users** (`/admin/register`).
   Δεν υπάρχει ελεύθερη εγγραφή: τους λογαριασμούς τους φτιάχνει ο διαχειριστής.
3. Σε κάθε project, διάλεξε compiler από **Menu → Settings → Compiler**
   (π.χ. XeLaTeX για `fontspec`/`mathspec`/ελληνικές γραμματοσειρές).

## Επιλογές

| Επιλογή | Περιγραφή |
|---|---|
| `--site-url URL` | Η διεύθυνση του site (προεπιλογή: `http://<IP του μηχανήματος>`) |
| `--app-name NAME` | Όνομα στο interface (προεπιλογή: `LaTeX Editor`) |
| `--admin-email EMAIL` | Email επικοινωνίας στη σελίδα εγγραφής |
| `--dir PATH` | Φάκελος του toolkit (προεπιλογή: `/opt/overleaf-toolkit`) |
| `--port PORT` | Εσωτερική θύρα πίσω από το nginx (προεπιλογή: `8080`) |
| `--no-nginx` | Χωρίς nginx: το Overleaf ακούει απευθείας στη θύρα 80 |
| `--no-texlive-full` | Κράτα το βασικό TeX Live του image |
| `--accept-mscorefonts-eula` | Εγκατάσταση γραμματοσειρών Microsoft χωρίς ερώτηση (αποδοχή [EULA](https://corefonts.sourceforge.net/eula.htm)) |
| `--no-mscorefonts` | Χωρίς γραμματοσειρές Microsoft |
| `-y`, `--yes` | Χωρίς επιβεβαίωση |

Παράδειγμα, εντελώς αυτόματα:

```bash
sudo ./install.sh --yes --accept-mscorefonts-eula --site-url http://192.168.1.50 --app-name "LaTeX Editor"
```

Με `curl | sudo bash`, οι επιλογές μπαίνουν μετά το `-s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/install.sh | sudo bash -s -- --yes --accept-mscorefonts-eula
```

## Διαχείριση

```bash
cd /opt/overleaf-toolkit
bin/up -d      # εκκίνηση
bin/stop       # διακοπή
bin/logs       # logs
bin/doctor     # διάγνωση
```

Τα δεδομένα (projects, χρήστες) βρίσκονται στο `/opt/overleaf-toolkit/data`. **Κράτα backup.**

### Αναβάθμιση του Overleaf

Μια νέα έκδοση του Overleaf έρχεται ξανά με το βασικό TeX Live. Για αναβάθμιση:

```bash
cd /opt/overleaf-toolkit
bin/upgrade                        # επίσημη αναβάθμιση: νέο toolkit και νέα έκδοση Overleaf
cd - && sudo ./install.sh --yes    # ξαναστήνει TeX Live και γραμματοσειρές στη νέα έκδοση
```

Διάβασε πρώτα το [CHANGELOG του toolkit](https://github.com/overleaf/toolkit/blob/master/CHANGELOG.md):
κάποιες αναβαθμίσεις απαιτούν και νεότερη MongoDB.

### HTTPS

Για πρόσβαση από το internet, βάλε το site πίσω από HTTPS (π.χ. Let's Encrypt με `certbot --nginx`
ή Cloudflare) και ξανατρέξε το script με `--site-url https://...`. Με `https://` ενεργοποιούνται
αυτόματα τα secure cookies. Με `http://` μένουν απενεργοποιημένα, αλλιώς ο browser απορρίπτει το
cookie της σύνδεσης ("Session error").

## Αντιμετώπιση προβλημάτων

| Σύμπτωμα | Αιτία / λύση |
|---|---|
| `Session error. Please check you have cookies enabled` | Το `OVERLEAF_SECURE_COOKIE` υπάρχει σε site με `http://`. Το Overleaf ενεργοποιεί τα secure cookies όποια τιμή κι αν έχει. Το script το αφαιρεί. |
| Το container `mongo` κάνει συνέχεια restart | Kernel ≥ 6.19 (`docker logs mongo` γράφει "Linux kernel versions 6.19 and newer"). Το script προσθέτει τη διόρθωση στο `config/docker-compose.override.yml`. |
| `File 'xxx.sty' not found` | Λείπει το πλήρες TeX Live: ξανατρέξε χωρίς `--no-texlive-full`. |
| `The font "Times New Roman" cannot be found` | Ξανατρέξε με `--accept-mscorefonts-eula`. |
| Τα αρχεία ενός project δεν βρίσκονται μετά από upload zip | Το Overleaf αφαιρεί τον εξωτερικό φάκελο του zip. Διόρθωσε τις διαδρομές (π.χ. `Thesis template/figures/` → `figures/`). |

## Άδειες

- Το script διατίθεται με την άδεια [MIT](LICENSE).
- Το [Overleaf](https://github.com/overleaf/overleaf) διατίθεται με την άδεια AGPL-3.0, και το
  "Overleaf" είναι εμπορικό σήμα της Overleaf. Το script δεν περιέχει κώδικα του Overleaf: κατεβάζει
  τα επίσημα images και το toolkit.
- Οι γραμματοσειρές Microsoft δεν περιλαμβάνονται εδώ. Το πακέτο `ttf-mscorefonts-installer` τις
  κατεβάζει μόνο αν αποδεχτείς την [EULA](https://corefonts.sourceforge.net/eula.htm) τους.

---

## English summary

`install.sh` sets up Overleaf Community Edition on Ubuntu/Debian x86_64 with one command, using the
official [overleaf/toolkit](https://github.com/overleaf/toolkit). It installs Docker, full TeX Live
(with rebuilt formats and TeX Live fonts registered for XeLaTeX), and optionally the Microsoft core
fonts after you accept their EULA. It commits the result to a local image so a restart keeps it, and
configures an nginx reverse proxy. It also works around MongoDB 8 failing to start on Linux kernels
≥ 6.19. It is idempotent, and `./install.sh --help` lists the options. After installing, open
`/launchpad` to create the first admin account.
