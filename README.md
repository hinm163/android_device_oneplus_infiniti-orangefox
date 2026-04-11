# OnePlus 15 infiniti OrangeFox device tree

## Working

- [X] Display
- [X] Touch 
- [X] Decryption
- [X] Flashing
- [X] Backup & Restore
- [X] KernelSU, KernelSU Next & SukiSU Ultra Installer
- [X] MTP/OTG Storage
- [X] ADB/FastbootD
- [X] Factory Reset
- [X] Vibrator
- [X] Display & Vibration Settings
- [X] Flashlight

## Not working

- [ ] ???????

# How To Build

### Clone & Sync Source
```
mkdir -p ~/android/OrangeFox_16
cd ~/android/OrangeFox_16
git clone https://github.com/OrangeFox16/sync.git
cd sync
./orangefox_sync.sh --branch 16.0 --path ~/android/fox_16.0
```
### Clone Device-tree
```
cd ~/android/fox_16.0/device
mkdir -p oneplus
cd oneplus
git clone https://github.com/koaaN/android_device_infiniti-orangefox -b fox_16.0 infiniti
```
### BUILD!
```
cd ~/android/fox_16.0
source build/envsetup.sh
lunch twrp_infiniti-bp2a-eng
mka adbd recoveryimage
```
