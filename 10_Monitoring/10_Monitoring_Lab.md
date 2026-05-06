# Тема 10: Моніторинг, стабільність та логування — Лабораторна робота

> **Статус:** Ready for Students
> **Файл для студентів.** Практична частина до теорії `10_Monitoring_Theory.md`.

---

## 🗺 Де ми зараз? Підсумок пройденого шляху

Всі попередні лабораторні роботи (Теми 6–9) були присвячені одному великому процесу: **Delivery** (доставці коду на сервер). Ми створили сервер (Vagrant), налаштували його (Ansible), запустили сервіс (systemd), підняли базу (Docker) і автоматизували оновлення через CI/CD.

Тепер наш код успішно живе в "production". Але робота DevOps-інженера на цьому не закінчується. CI/CD каже, що код доїхав. А хто скаже, чи він досі працює?

У цій лабораторній роботі ми переходимо до етапу **Operation та Monitoring**. Ми створимо просту, але дієву систему контролю стабільності для нашого `training-project`. Це мініатюрна версія того, що в реальному житті роблять інструменти на зразок Prometheus. Важливо, що цього разу ми одразу збережемо артефакти моніторингу в Git і розгорнемо їх через Ansible, щоб вони були відтворюваними так само, як сервіс і база даних у попередніх темах.

---

## 🎯 Мета роботи

Налаштувати базовий механізм моніторингу стабільності сервісу.
Після виконання роботи ви матимете скрипт `monitor.sh`, який регулярно опитує Flask-додаток, веде історію перевірок у лог-файлі, генерує `[ALERT]` із захистом від мікро-збоїв, запускається автоматично через `systemd timer` та розгортається через Ansible playbook. Також ви навчитеся використовувати `journalctl` для розуміння причин збою і порахуєте простий SLI на основі зібраних логів.

---

## 🛠 Покрокова інструкція

### Крок 1: Перевірка передумов

Спочатку переконаємось, що система-пацієнт (наша віртуальна машина) жива.

На **хості** (вашому ноутбуці):

```bash
# Переходимо в папку проєкту
cd ~/devops-course/training-project/

# Перевіряємо статус ВМ
vagrant status

# Якщо вона зупинена, піднімаємо
vagrant up

# Перевіряємо, що health-endpoint нашого сервісу відповідає
ssh vagrant@192.168.56.10 "curl -s http://localhost:5000/health"
```

**Очікуваний результат:** команда `curl` має повернути `{"status": "ok"}`. Це означає, що сервіс готовий до моніторингу.

Якщо щось не працює, спочатку повторно застосуйте `ansible-playbook` (як у Темах 7-8):

```bash
cd ~/devops-course/training-project/ansible/
ansible-playbook playbook.yml -e "db_password=ВашПароль123"
```

---

### Крок 2: Створення базового скрипта моніторингу на хості

У попередніх темах ми вже побачили головний принцип IaC: якщо артефакт не живе в Git, він не є відтворюваним. Тому `monitor.sh` ми створюємо не прямо на VM, а відразу в репозиторії `training-project`, щоб потім розгорнути його через Ansible.

На **хості**, у корені `training-project/`, створіть файл `monitor.sh`:

```bash
touch monitor.sh
chmod +x monitor.sh
```

Відкрийте `monitor.sh` і додайте в нього такий код:

```bash
#!/bin/bash

URL="http://localhost:5000/health"
LOG_FILE="/opt/training-app/monitor.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$URL")

if [ "$HTTP_CODE" = "200" ]; then
    echo "[$TIMESTAMP] INFO: Service is healthy (HTTP 200)" >> "$LOG_FILE"
else
    echo "[$TIMESTAMP] ERROR: Service returned HTTP $HTTP_CODE" >> "$LOG_FILE"
fi
```

Цей скрипт ще дуже простий: він просто робить HTTP-запит до `/health`, бере лише статус-код і записує результат у лог-файл.

---

### Крок 3: Додаємо захист від Alert Fatigue

Як ми обговорювали в теорії, будити інженера через один випадковий збій мережі не можна. Наш моніторинг має підняти тривогу тільки якщо сервіс лежить **стабільно**: наприклад, три перевірки поспіль.

Оновіть файл `monitor.sh`, замінивши його вміст на цей:

```bash
#!/bin/bash

URL="http://localhost:5000/health"
LOG_FILE="/opt/training-app/monitor.log"
STATE_FILE="/opt/training-app/.monitor_state"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

if [ ! -f "$STATE_FILE" ]; then
    echo "0" > "$STATE_FILE"
fi

FAILURES=$(cat "$STATE_FILE")
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$URL")

if [ "$HTTP_CODE" = "200" ]; then
    echo "[$TIMESTAMP] INFO: Service is healthy (HTTP 200)" >> "$LOG_FILE"
    echo "0" > "$STATE_FILE"
else
    echo "[$TIMESTAMP] ERROR: Service returned HTTP $HTTP_CODE" >> "$LOG_FILE"

    FAILURES=$((FAILURES + 1))
    echo "$FAILURES" > "$STATE_FILE"

    if [ "$FAILURES" -ge 3 ]; then
        echo "[$TIMESTAMP] [ALERT] Service failed $FAILURES times in a row! Requires investigation." >> "$LOG_FILE"
    fi
fi
```

Що змінилося:

- з'явився `STATE_FILE`, у якому ми тримаємо кількість помилок поспіль;
- після успішної перевірки лічильник скидається в `0`;
- після трьох збоїв поспіль скрипт пише `[ALERT]` у лог.

Тепер наш моніторинг "розумний" — він прощає поодинокі помилки і починає сигналізувати лише коли сервіс дійсно лежить.

---

### Крок 4: Створення `systemd` unit-файлів і інтеграція в Ansible playbook

Щоб скрипт став справжньою системою моніторингу, він має запускатися сам. Ми вже вивчили `systemd` у Темі 7, тому використаємо `systemd timer`, а не `cron`. Це дає дві переваги:

- запуск за розкладом теж стає частиною IaC;
- логи моніторингу можна дивитися через `journalctl`, так само як і логи застосунку.

На **хості**, у корені `training-project/`, створіть файл `monitor.service`:

```ini
[Unit]
Description=Training App Health Monitor
After=network.target

[Service]
Type=oneshot
ExecStart=/opt/training-app/monitor.sh
User=training
```

> 💡 **Чому `User=training`, а не `root`?** Моніторинг-скрипт робить лише HTTP-запит до `/health` і пише у файл — для цього не потрібні адміністративні права. Дотримання принципу **Least Privilege** (найменших привілеїв) означає: кожен сервіс працює лише з тими правами, які йому дійсно потрібні. У реальній практиці сервіси моніторингу (Prometheus, Nagios, Zabbix) взагалі мають власних окремих користувачів без `sudo`. У нашому випадку `training` — сервісний акаунт з Теми 6, який вже має доступ до `/opt/training-app/`.

Створіть файл `monitor.timer`:

```ini
[Unit]
Description=Run health monitor every minute

[Timer]
OnCalendar=*-*-* *:*:00
Persistent=true

[Install]
WantedBy=timers.target
```

Створіть файл `monitor-logrotate` у корені `training-project/`:

```text
/opt/training-app/monitor.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
}
```

> 💡 **Зверніть увагу:** `/opt/training-app/monitor.log` всередині файлу — це шлях до логу **на віртуальній машині**, який `logrotate` буде ротувати. Сам цей конфігураційний файл Ansible розмістить у `/etc/logrotate.d/monitor` — про це далі в задачах playbook.
>
> **Як працює `logrotate`:** система має єдину директорію `/etc/logrotate.d/`, де лежать конфіги для різних логів. Системний `cron` щодня запускає `logrotate`, той обходить усі файли в цій директорії і ротатує логи згідно з їхніми правилами. Наш файл `monitor-logrotate` після копіювання Ansible стає одним із таких конфігів.

**Що цей конфіг робить:**

- `daily` — ротувати лог раз на добу;
- `rotate 7` — зберігати 7 старих архівів (тиждень історії);
- `compress` — стискати старі логи через `gzip`;
- `missingok` — не панікувати, якщо файл ще не існує;
- `notifempty` — не ротувати порожній файл.

Тепер відкрийте `ansible/playbook.yml` і додайте задачі для розгортання моніторингу. Найзручніше додати їх після задачі запуску PostgreSQL-контейнера.

```yaml
    - name: Скопіювати скрипт моніторингу
      copy:
        src: ../monitor.sh
        dest: "{{ app_dir }}/monitor.sh"
        owner: "{{ app_user }}"
        group: "{{ app_user }}"
        mode: '0755'

    - name: Переконатися, що лог-файл моніторингу існує
      file:
        path: "{{ app_dir }}/monitor.log"
        state: touch
        owner: "{{ app_user }}"
        group: "{{ app_user }}"
        mode: '0644'

    - name: Скопіювати unit-файл monitor.service
      copy:
        src: ../monitor.service
        dest: /etc/systemd/system/monitor.service
        owner: root
        group: root
        mode: '0644'
      notify:
        - Reload systemd

    - name: Скопіювати unit-файл monitor.timer
      copy:
        src: ../monitor.timer
        dest: /etc/systemd/system/monitor.timer
        owner: root
        group: root
        mode: '0644'
      notify:
        - Reload systemd

    - name: Скопіювати конфігурацію logrotate для моніторингу
      copy:
        src: ../monitor-logrotate
        dest: /etc/logrotate.d/monitor
        owner: root
        group: root
        mode: '0644'

    - name: Активувати monitor.timer
      systemd:
        name: monitor.timer
        enabled: yes
        state: started
```

Якщо у playbook вже є handler `Reload systemd` з Теми 7, використайте його. Якщо ні, додайте секцію `handlers`:

```yaml
  handlers:
    - name: Reload systemd
      systemd:
        daemon_reload: yes
```

Тепер застосуйте playbook:

```bash
cd ansible/
ansible-playbook playbook.yml -e "db_password=ВашПароль123"
```

Після завершення перевірте результат:

```bash
ssh vagrant@192.168.56.10 "sudo systemctl status monitor.timer --no-pager"
ssh vagrant@192.168.56.10 "sudo systemctl list-timers monitor.timer --no-pager"
ssh vagrant@192.168.56.10 "sudo ls -l /opt/training-app/monitor.sh /opt/training-app/monitor.log"
```

**Очікуваний результат:** `monitor.timer` має бути `active (waiting)`, у списку таймерів має бути наступний запуск, а файли `monitor.sh` і `monitor.log` мають існувати в `/opt/training-app/`.

---

### Крок 5: Імітація аварії (Chaos Engineering)

Час перевірити, чи спрацює наш моніторинг у бойових умовах. Ми свідомо "вб'ємо" сервіс.

На VM відкрийте другий термінал або в цьому ж терміналі почніть безперервно читати лог:

```bash
ssh vagrant@192.168.56.10
sudo tail -f /opt/training-app/monitor.log
```

Ви побачите, як кожну хвилину додається новий рядок `INFO: Service is healthy`.

Не зупиняючи `tail` (або в сусідньому вікні терміналу), зупиніть Flask-додаток:

```bash
sudo systemctl stop training-app
```

Спостерігайте за `monitor.log`:

1. На першій хвилині ви побачите помилку (`HTTP 000`, бо порт не відповідає).
2. На другій хвилині буде друга помилка.
3. На третій хвилині з'явиться `[ALERT]`.

Моніторинг працює: він помітив не випадковий збій, а стійку проблему.

Тепер подивіться логи самого таймера і сервісу моніторингу:

```bash
sudo journalctl -u monitor.service --no-pager | tail -n 20
sudo systemctl status monitor.timer --no-pager
```

Це важливий момент: наш механізм моніторингу теж став спостережуваним. Ми можемо перевірити не лише стан Flask-додатку, а й сам факт виконання перевірок.

---

### Крок 6: Від Моніторингу до Observability (`journalctl`)

Отже, моніторинг повідомив нам: "Сервіс не відповідає". Але він не каже **чому**. Для цього потрібна **Observability** — вивчення логів самого сервісу.

Подивимось логи застосунку:

```bash
# Переглядаємо останні події training-app
sudo journalctl -u training-app --no-pager | tail -n 20
```

Ви маєте побачити записи про те, що сервіс отримав сигнал `SIGTERM` і коректно зупинився. `SIGTERM` — це стандартний сигнал Linux, який означає «процес має завершитися». На відміну від `SIGKILL` (`kill -9`), який вбиває процес миттєво, `SIGTERM` дає процесу час закрити з'єднання, дописати логи і завершитися чисто. Саме цей сигнал відправляє `systemctl stop` — у Темі 7 при вивченні systemd і в Кроці 5 цієї лабораторної, коли ми свідомо зупиняли сервіс.

Тепер порівняйте два джерела логів:

```bash
# Зовнішній симптом
sudo tail -n 5 /opt/training-app/monitor.log

# Внутрішня причина
sudo journalctl -u training-app --no-pager | tail -n 5
```

Перший файл показує симптом: healthcheck не проходить. Другий показує внутрішні події застосунку.

Запустіть сервіс назад:

```bash
sudo systemctl start training-app
```

Через хвилину перевірте, що моніторинг знову бачить систему як здорову:

```bash
sudo tail -n 5 /opt/training-app/monitor.log
```

Очікувано, наступний запис має бути `INFO: Service is healthy`. Інцидент вичерпано.

---

### Крок 7: Обчислення простого SLI з логів

Тепер використаємо зібрані логи не лише для читання, а й для вимірювання. Це і є перший крок до SLI/SLO.

На VM виконайте:

```bash
TOTAL=$(grep -c "INFO\|ERROR" /opt/training-app/monitor.log)
OK=$(grep -c "INFO" /opt/training-app/monitor.log)
echo "SLI: $OK успішних перевірок з $TOTAL"
echo "SLI у відсотках: $(( OK * 100 / TOTAL ))%"
```

**Що тут відбувається:**

- `TOTAL` рахує всі перевірки, які дали або `INFO`, або `ERROR`;
- `OK` рахує лише успішні перевірки;
- останній рядок переводить це у відсоток успішності.

Якщо, наприклад, у вас 18 успішних перевірок з 20, то SLI дорівнює `90%`. Це ще не SLO, а лише фактично виміряний показник. Але саме з таких чисел починається розмова про надійність сервісу.

---

### Крок 8: Перевірка повної відтворюваності через Ansible

Головна ідея цієї лабораторної: моніторинг не повинен жити лише в пам'яті адміністратора або в ручних діях на сервері. Він має відтворюватися так само, як сервіс і база даних.

На **хості**, з каталогу `training-project/`, виконайте:

```bash
vagrant destroy -f
vagrant up

cd ansible/
ansible-playbook playbook.yml -e "db_password=ВашПароль123"
```

Після цього перевірте нову VM:

```bash
ssh vagrant@192.168.56.10 "sudo systemctl is-active training-app"
ssh vagrant@192.168.56.10 "sudo systemctl is-active monitor.timer"
ssh vagrant@192.168.56.10 "sudo systemctl list-timers monitor.timer --no-pager"
ssh vagrant@192.168.56.10 "curl -s http://localhost:5000/health"
```

**Очікуваний результат:** `training-app` активний, `monitor.timer` активний, таймер запланований, `/health` відповідає `{"status":"ok"}`. Це означає, що ми відтворили з нуля не лише застосунок, а й його моніторинг.

---

### Крок 9: Збереження змін у Git

Моніторинг тепер теж є частиною `training-project`, тому його потрібно зберегти в Git як новий інфраструктурний артефакт.

На **хості**, з кореня `training-project/`:

```bash
git add monitor.sh monitor.service monitor.timer monitor-logrotate ansible/playbook.yml
git commit -m "Add monitoring healthcheck script, systemd timer and logrotate"
git push
```

**Очікуваний результат:** зміни збережені в GitHub. Тепер будь-хто з командою може відтворити повне середовище разом із моніторингом, а не налаштовувати його вручну після деплою.

---

## ✅ Результат виконання роботи

Після виконання лабораторної роботи у вас має бути:

- [ ] У репозиторії є файли `monitor.sh`, `monitor.service`, `monitor.timer`, `monitor-logrotate`
- [ ] `monitor.sh` розгортається в `/opt/training-app/monitor.sh` через Ansible
- [ ] `monitor.timer` запущений і виконує перевірку щохвилини
- [ ] Конфігурація `logrotate` розгорнута в `/etc/logrotate.d/monitor`
- [ ] У файлі `/opt/training-app/monitor.log` з'являються записи про стан сервісу
- [ ] Після зупинки `training-app` у логах з'являється `[ALERT]`
- [ ] Ви вмієте дивитися `journalctl -u training-app` і `journalctl -u monitor.service`
- [ ] Ви порахували простий SLI на основі `monitor.log`
- [ ] Після `vagrant destroy -f && vagrant up && ansible-playbook playbook.yml` моніторинг відтворюється автоматично

---

## ❓ Контрольні питання

> Дайте відповіді письмово або усно перед захистом роботи. Відповіді можна шукати в лекції або спираючись на отриманий досвід.

1. У чому різниця між записами в `monitor.log`, логами `journalctl -u monitor.service` і логами `journalctl -u training-app`?
2. Якби ми налаштували скрипт відправляти alert при **першому ж** збої (`FAILURES=1`), до яких наслідків це призвело б у великому проєкті?
3. Що означає HTTP статус `000`, який повертав `curl` під час зупиненого сервісу?
4. Чому ми перевіряємо стан системи запитом `curl http://localhost:5000/health`, а не просто командою `systemctl is-active training-app`?
5. Чому в цій лабораторній ми використовуємо `systemd timer`, а не `cron`?
6. Чому `monitor.sh`, `monitor.service` і `monitor.timer` потрібно зберігати в Git і розгортати через Ansible, а не створювати вручну прямо на VM?
7. Уявімо, що сервіс підключений до PostgreSQL (з Теми 8). Якщо PostgreSQL зупиниться, але сам Flask працюватиме, що покаже наш healthcheck і чому?
