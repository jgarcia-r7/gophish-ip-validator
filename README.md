# gophish-ip-validator
Differentiate machine clicks and human clicks based on IP addresses and known ASNs.
## Usage
Download the raw events CSV file from a completed GoPhish campaign. Use the script as follows:
```bash
./gophish-ip-validator.sh GOPHISH_EVENTS_FILE.csv COMPANY_CLICKED_LINK
```
The script will then extract all unique IP addresses that have the "Clicked Link" flag from the GoPhish events file. It will then check locally for an exclude_me.txt file and a cidr_blocks.txt - both are created when first executed. 
The IP is determined to be a machine click if it's in the exclude_me.txt file or belongs to a range in the cidr_blocks.txt file. If neither are true, it will then perform a request to 'https://ifconfig.co' and check what the ASN is.
Currently, the script checks for common ASNs, such as Amazon, Google, Microsoft, Proofpoint, etc. In the case of Amazon, it checks if it's an ec2 instance and counts that as a human click.
## Sreenshots
Usage:  
![image](https://github.com/user-attachments/assets/b8204501-c614-46ba-a6e2-f12736d10ce7)  
Output:  
![image](https://github.com/user-attachments/assets/ac5f434b-01fc-4dce-80c2-577e693660a4)
