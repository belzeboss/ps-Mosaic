PowerShell Core Module to create Mosaics

Uses Interleaved Color Values to create a look-up-table for the colours.
## Description
### Analyze the source tiles

The `CreateNail` function crops an image and returns the cropped image as bitmap. With the `OutILCInfo`-switch the bitmap is disposed and the ILC-information is printed out instead. The format of the ILC-Information-String is as follows:
```
"${ilc}_${XPortion}_${YPortion}_${Scale}_${w}_${h}_$ImagePath"
```
This information can also be passed in as input with `InILCInfo` in order to create the cropped bitmap with those respective paramters.
Run this command on all your source files and save the output as a list. For example
```
CreateNail -ImagePath $ImagePath -w 100 -h 100 -XPortion 0.5 -YPortion 0.5 -Scale 1 -OutILCInfo 
```
will create a cropped bitmap, positioned in the middle with the maximum size and return the ILC information of that cropped "nail". This is done with the function `GetAvgILC`, which calulates the average of all channels and interleaves them into a single value with `BitInterleave`. A helper function, `GetAllILCInfo` helps to create center, left, right and corners (at 70% size) ILC infos for a given path. Paired with `Out-File` a file containing all the ILC-Informations of you source imagepaths can be created. With that file we can now create mosaics.

### Create the Mosaic
From here the mosaic can be created by calling `CreateMosaic` with the `ILCPaths` parameter set to the afirmentioned file(s). The default is to take all .txt files in the current directory as ILC-Infos, in case no parameter is provided. The `Size` Parameter is the width and height of each tile in the mosaic. The `Count` Parameter denotes how many tiles will be put next to each other in width. `AlphaBlend` allows you to blend the target color over the choosen tile. The range of choosen tiles can also be extended with `Tolerance`, which extends the ILC-Range and creates a bigger pool of tile-paths. One of them ultimatley is choosen, randomly.

## Example
Create all ILC infos for all images in the ImageFolder. The ILC is calculated on a sample of 100x100 pixels:
```
gci $ImageFolder | GetAllILCInfo -Width 100 -Height 100 | Out-File ILC100.txt
```
Now this can take a good while and can most likely optimized tremendously. After the list is constructed we choose a random image in the ImageFolder, that we create a mosaic for. We use 1% Tolerance here, but typically this depends on the ILC-List and how distributed they are.
```
gci $ImageFolder | Get-Random | CreateMosaic -Alpha 20 -Size 40 -Count 50 -Tolerance 1 -ILCPath ILC100.txt
```
