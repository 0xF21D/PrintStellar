# PrintStellar
PowerShell Script to assist Windows Server administrators with identifying and disabling the print spooler service on servers where it is not needed. Inspired by PrintNightmare
 
Description: This script queries the print spooler status and installed printers for all windows servers in a domain. It results in a $report object that can then be parsed in different ways to determine what servers have additional printers installed outside of the default microsoft printers. It can then be configured to disable the print spooler. See the options below for addtional options. 

If configured to disable the spooler, the default behavior is to disable the spooler on all servers where the only printers installed (if any) are listed in the $PrinterIgnoreList below. This is configured default to Microsoft XPS and PDF printers. Add servers that you don't want to disable to the $ServerIgnoreList below

The script exports a report.csv file to your desktop for ease of audit and viewing of results. 

Right now it is recommended to run this script in ISE or VSCode after modification (and audit). Note that you can run this as your normal account, or run from a server. You will be prompted for appropriate credentials. Also note that you shouldabsolutely run this first with $DisableMode set to false for purpose of discovery.
