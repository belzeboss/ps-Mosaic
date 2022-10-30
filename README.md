PowerShell Core Module to create Mosaics

Uses Interleaved Color Values to create a look-up-table for the colours.

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

From here the mosaic can be created by calling `CreateMosaic` with the `ILCPaths` parameter set to the afirmentioned file(s). The default is to take all .txt files in the current directory as ILC-Infos, in case no parameter is provided.

