Firmware that build-rootfs.sh copies into /usr/lib/firmware (this folder mirrors that directory):

  wcnss.mdt + wcnss.b00 ...                  Wi-Fi/Bluetooth chip (DTS has no firmware-name, so the kernel asks for the bare name)
  wlan/prima/WCNSS_qcom_wlan_nv.bin          Wi-Fi calibration
  adsp.mdt + adsp.b00 ... (adsp.mbn)         audio DSP (relocatable, 16 MiB)
  qcom/a530_pm4.fw, qcom/a530_pfp.fw         Adreno 510 microcode (redistributable, from linux-firmware)

The wcnss/adsp files are signed and per-device: copied from YOUR phone's modem partition, not downloadable. If something is
missing, run on the phone:   sudo kenzo-wifi diag      (what is missing and why)
                             sudo kenzo-wifi firmware  (copies from the phone's own partitions)
