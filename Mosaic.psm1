Add-Type -Name "Global" -Namespace "Tools" -ReferencedAssemblies System.Collections.dll -MemberDefinition '
public static int BinarySearch<T>(System.Collections.Generic.IList<T> list, T value)
{
    if (list == null)
        throw new ArgumentNullException("list");
    var comp = System.Collections.Generic.Comparer<T>.Default;
    int lo = 0, hi = list.Count - 1;
    while (lo < hi) {
		int m = (hi + lo) / 2;  // this might overflow; be careful.
		if (comp.Compare(list[m], value) < 0) lo = m + 1;
		else hi = m - 1;
    }
    if (comp.Compare(list[lo], value) < 0) lo++;
    return lo;
}'

# Helper function to find the tile-path (ILC-Info) in $ilcMap based on the $ilc
function GetTileProvider
{
	param(
		$ilcMap,
		$sortedIlc,
		$ilc,
		$ilcTolerance
	)
	if ($sortedIlc.Count -eq 0){
		return $null
	}
	# find closest index
	$closestIndex = [Tools.Global]::BinarySearch($sortedIlc, [long]$ilc)

	$pathCount = 0
	$ilcPathsList = [System.Collections.Generic.List[System.Collections.Generic.List[string]]]::new()

	# collect path-lists down to lower-ilc
	$lowerIlc = $ilc - $ilcTolerance
	$index = if ($closestIndex -eq 0){0}else{$closestIndex-1}
	while($sortedIlc[$index] -ge $lowerIlc){
		$ilcPaths = $ilcMap[$sortedIlc[$index]]
		$ilcPathsList.Add($ilcPaths)
		$pathCount += $ilcPaths.Count
		$index--
		if ($index -lt 0){ break }
	}
	# collect path-lists up to upper-ilc
	$upperIlc = $ilc + $ilcTolerance
	$index = if ($closestIndex -ge ($sortedIlc.Count-1)){$sortedIlc.Count-1}else{$closestIndex+1}
	while($sortedIlc[$index] -le $upperIlc){
		$ilcPaths = $ilcMap[$sortedIlc[$index]]
		$ilcPathsList.Add($ilcPaths)
		$pathCount += $ilcPaths.Count
		$index++
		if ($index -ge $sortedIlc.Count){ break }
	}
	# if no path has been found, add closest path-list
	if ($pathCount -eq 0){
		$a = $ilc - $sortedIlc[$closestIndex]
		$b = $sortedIlc[$closestIndex+1] - $ilc
		$closestIlc = if ($a -gt $b){
			# upper bound is closer to ilc
			$sortedIlc[$closestIndex+1]
		}
		else {
			# lower bound is closer to ilc
			$sortedIlc[$closestIndex]
		}
		$ilcPaths = $ilcMap[$closestIlc]
		$ilcPathsList.Add($ilcPaths)
		$pathCount += $ilcPaths.Count
	}
	# uniformly select a random path from all the path-lists
	$pathNumber = [random]::Shared.next($pathCount)
	$ilcIndex = 0
	while($pathNumber -ge $ilcPathsList[$ilcIndex].Count){
		$pathNumber -= $ilcPathsList[$ilcIndex].Count
		$ilcIndex++
	}
	return $ilcPathsList[$ilcIndex][$pathNumber]
}
# Create the mosaic
function CreateMosaic
{
	[cmdletbinding()]
	param(
		[Parameter(ValueFromPipeline=$true)][string]$Path,
		[string[]]$ILCFiles = "$pwd\*.txt",
		[int]$Count = 20,
		[int]$Size = 30,
		[double]$Tolerance = 1,
		[double]$AlphaBlend = 0,
		[switch]$DynamicTolerance,
		[switch]$AsJob,
		[switch]$OutILCInfo
	)
	begin{
		# in a job-setting, do this every time to avoid passing ilcMap to the job
		if (-not $AsJob.IsPresent){
			# based on max ILC (white)
			$ilcTolerance = (BitInterleave 255,255,255 8) * $Tolerance / 200
			# load ilc-map from ILCFiles (ILC 1:n image-path)
			$ilcMap = [System.Collections.Generic.Dictionary[long, [System.Collections.Generic.List[string]]]]::new()
			$ILCFiles | gc | %{
				$info = "$_".Split("_"[0], 2)
				# get ILC_XXX;; copy the whole command in, to be interpreted by CreateNail itself
				$ilc = [convert]::ToUInt32($info[0])
				if (-not $ilcMap.ContainsKey($ilc)){
					$null = $ilcMap.Add($ilc, [System.Collections.Generic.List[string]]::new())
				}
				$ilcMap[$ilc].Add("$_")
			}
			# list of sorted ILCs
			$sortedIlc = [System.Collections.Generic.List[long]]::new($ilcMap.Keys)
			$sortedIlc.Sort()
			Write-Information "Loaded $($sortedIlc.Count) ILCs"
		}
	}
	process{
		# start the job with different source-image
		if ($AsJob.IsPresent){
			$module = (get-command CreateMosaic).Module.Path
			return Start-Job -ScriptBlock {
				import-module $args[0]
				CreateMosaic -Path:$args[1] -ILCFiles:$args[2] -Count:$args[3] -Size:$args[4] -Tolerance:$args[5] -AlphaBlend:$args[6] -DynamicTolerance:$args[7]
			} -ArgumentList $module,$Path,$ILCFiles,$Count,$Size,$Tolerance,$AlphaBlend,$DynamicTolerance
		}

		# The must exist, relative or not; But for "FromFile" we need the absolute path
		$Path = Resolve-Path $Path
		# load image
		$image = [System.Drawing.Image]::FromFile($Path)
		# 
		$sampleSize = [math]::Floor($image.Width / $Count)
		$TileYCount = [math]::Floor($image.Height / $sampleSize)

		$ilcInfo = $null
		$finalImage = $null
		$rowImage = $null
		for ($y=0; $y -lt $TileYCount; ++$y){
			$finalImage = CombineImage $finalImage $rowImage -Down
			$rowImage = $null
			for($x=0; $x -lt $Count; ++$x) {
				$progress = $x + $y * $Count
				$percentage = $progress / ($TileYCount * $Count) * 100
				Write-Progress -PercentComplete $percentage -Activity "Building Mosaic"

				# sample rectangle for ilc
				$r = [System.Drawing.Rectangle]::new($x*$sampleSize,$y*$sampleSize,$sampleSize,$sampleSize)
				$ilc = GetAvgILC -Bitmap $image -Rect $r

				if ($DynamicTolerance.IsPresent){ $ilcTolerance = $ilc * $Tolerance / 100.0 }

				if ($sortedIlc.Count -gt 0){
					$ilcInfo = GetTileProvider $ilcMap $sortedIlc $ilc $ilcTolerance

					if ($OutILCInfo.IsPresent){
						Write-Output $ilcInfo
					}
				}

				$tile = CreateNail -InILCInfo $ilcInfo -w $Size -h $Size -AlphaBlend ($AlphaBlend/100.0) -BlendIlc $ilc

				if([System.Random]::Shared.Next(2) -eq 0){
					$tile.RotateFlip([System.Drawing.RotateFlipType]::RotateNoneFlipX)
				}

				if ($null -eq $rowImage){
					$rowImage = $tile
				}
				else {
					$rowImage = CombineImage -i1 $rowImage -i2 $tile
				}
			}
		}
		$name = [io.path]::GetFileNameWithoutExtension($Path)
		$name = "T${Tolerance}A${AlphaBlend}__$name"
		$path = "$pwd/$name.bmp"
		$fileIndex = 0
		while (test-path $path){
			$suffix = "$fileIndex".PadLeft(3, "0")
			$path = "$pwd/${name}_$suffix.bmp"
			$fileIndex++
		}
		$finalImage.Save($path)
		$image.Dispose()
		return $path
	}
}

function CombineImage
{
	param(
		[System.Drawing.Image]$i1,
		[System.Drawing.Image]$i2,
		[switch]$Down
	)

	if ($null -eq $i1){
		return $i2
	}
	if ($null -eq $i2){
		return $i1
	}

	if ($Down.IsPresent)
	{
		$w = if ($i1.Width -gt $i2.Width){$i1.Width}else{$i2.Width}
		$h = $i1.Height + $i2.Height
	}
	else
	{
		$h = if ($i1.Height -gt $i2.Height){$i1.Height}else{$i2.Height}
		$w = $i1.Width + $i2.Width
	}
	$newBitmap = [System.Drawing.Bitmap]::new($w,$h, $i1.PixelFormat)
	$g = [System.Drawing.Graphics]::FromImage($newBitmap)
	$g.DrawImage($i1, 0, 0, $i1.Width, $i1.Height)
	if ($Down.IsPresent)
	{
		$g.DrawImage($i2, 0, $i1.Height, $i2.Width, $i2.Height)
	}
	else
	{
		$g.DrawImage($i2, $i1.Width, 0, $i2.Width, $i2.Height)
	}

	$null = $g.Save()
	$g.Dispose()

	$i1.Dispose()
	$i2.Dispose()

	return $newBitmap
}
filter GetAllILCInfo
{
	param(
		[Parameter(ValueFromPipeline=$true)][string]$ImagePath,
		[int]$Width = 10,
		[int]$Height = 10
	)

	try{
		$Image = [System.Drawing.Image]::FromFile($ImagePath)
		function center($p){
			CreateNail -ImagePath $ImagePath -Image $Image -w $Width -h $Height -OutILCInfo -XPortion 0.5 -YPortion 0.5 -Scale ($p/100)
		}
		function tiling($p) {
			if ($Image.Width * ($p/100) -lt $Width){
				return
			}
			if ($Image.Height * ($p/100) -lt $Height){
				return
			}
			for($xp = 0; $xp -le 100; $xp += $p)
			{
				for($yp = 0; $yp -le 100; $yp += $p)
				{
					CreateNail -ImagePath $ImagePath -Image $Image -w $Width -h $Height -OutILCInfo -XPortion ($xp/100) -YPortion ($yp/100) -Scale ($p/100)
				}
			}
		}
		tiling 50
		tiling 75
		tiling 100

		center 50
		center 75
		center 100
		$Image.Dispose()
	}
	catch{
		Write-Error "Could not get ILC from $ImagePath"
	}
}

function CreateNail
{
	param(
		[string]$ImagePath = $null,
		[System.Drawing.Image]$Image = $null,
		[int]$w = 500,
		[int]$h = 500,
		[float]$XPortion = 0.5,
		[float]$YPortion = 0.5,
		[float]$Scale = 1.0,
		[string]$InILCInfo,
		[double]$AlphaBlend,
		[int]$BlendIlc = -1,
		[switch]$OutILCInfo
	)

	if ("$InILCInfo".Length -gt 0){
		# "${ilc}_${XPortion}_${YPortion}_${Scale}_${w}_${h}_$ImagePath"
		$ilcInfo = "$InILCInfo".Split("_"[0], 7)
		$DiffuseIlc = [convert]::ToUInt32($ilcInfo[0])
		if ($ilcInfo.Count -ge 7){
			$XPortion = [convert]::ToDouble($ilcInfo[1])
			$YPortion = [convert]::ToDouble($ilcInfo[2])
			$Scale = [convert]::ToDouble($ilcInfo[3])
			#$w = [convert]::ToUInt32($ilcInfo[4])
			#$h = [convert]::ToUInt32($ilcInfo[5])
			$ImagePath = $ilcInfo[6]
			}
	}
	elseif ($BlendIlc -ge 0){
		$DiffuseIlc = $BlendIlc
	}

	$createdImage = $false
	# load image from ImagePath if unsepcified
	if ($null -eq $Image){
		if (-not (Test-Path -literalPath $ImagePath)){
			$Image = [System.Drawing.Bitmap]::new(1, 1, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
			$dif = BitExtraleave -Number $DiffuseIlc -Count 3
			$col = [System.Drawing.Color]::FromArgb(0,$dif[2],$dif[1],$dif[0])
			$Image.SetPixel(0, 0, $col)
			$AlphaBlend = 0
		}
		else {
			$Image = [System.Drawing.Image]::FromFile($ImagePath)
		}
		$createdImage = $true
	}

	# crop the srcRect into a square (shrink the larger dimension)
	$srcRect = [System.Drawing.Rectangle]::new(0, 0, $Image.Width*$Scale, $Image.Height*$Scale)


	if ($Image.Width -lt $Image.Height){

		$srcRect.Height = $srcRect.Width / ($w / $h)
	}
	else {
		$srcRect.Width =  $srcRect.Height * $w / $h
	}

	$srcRect.X = ($Image.Width - $srcRect.Width) * $XPortion
	$srcRect.Y = ($Image.Height - $srcRect.Height) * $YPortion

	# create the tile with RGB-Values
	$tile = [System.Drawing.Bitmap]::new($w, $h, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)

	# draw the image (srcRect) into the smaller tile and dispose of the original
	$g = [System.Drawing.Graphics]::FromImage($tile)
	$destRect = [System.Drawing.Rectangle]::new(0, 0, $w, $h)
	
	if (-not (Test-Path -LiteralPath $ImagePath)){
		$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
	}

	$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
	$g.DrawImage($Image, $destRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
	
	$null = $g.Save()
	$g.Dispose()

	if ($createdImage){
		$Image.Dispose()
	}

	# return the ILC-info (no blending is done!)
	if ($OutILCInfo.IsPresent){
		if ($null -eq $ImagePath) {
			$ImagePath = $Image.GetHashCode().ToString()
		}
		$ilc = GetAvgILC -Bitmap $tile
		return "${ilc}_${XPortion}_${YPortion}_${Scale}_${w}_${h}_$ImagePath"
	}

	# blend Tile-Pixels with Diffuse using AlphaBlend-Amount
	if ($AlphaBlend -gt 0){
		$data = $tile.LockBits($destRect, "ReadWrite", $tile.PixelFormat)
		$buf = [byte[]]::new(3 * $tile.Width)
		# not sure why this must be BGR instead of RGB; some endian stuff mayhaps
		$diffuseArray = BitExtraleave -Number $DiffuseIlc -Count 3
		$p = $data.Scan0
		for ($y = 0; $y -lt $h; ++$y){
			# copy scanline to buffer
			[System.Runtime.InteropServices.Marshal]::Copy($p, $buf, 0, $buf.Length)
			for($x = 0; $x -lt $buf.Length; ++$x){
				$value = $buf[$x] * (1-$AlphaBlend) + $diffuseArray[$x % 3] * $AlphaBlend
				$buf[$x] = [math]::clamp($value, 0, 255)
			}
			# copy the blended buffer back to the scanline
			[System.Runtime.InteropServices.Marshal]::Copy($buf, 0, $p, $buf.Length)
			$p = [System.IntPtr]::Add($p, $data.Stride)
		}
		$tile.UnlockBits($data)
	}
	return $tile
}
function GetAvgILC
{
	param(
		[Parameter(Mandatory=$true)][System.Drawing.Bitmap]$Bitmap,
		[System.Drawing.Rectangle]$Rect
	)
	if ($null -eq $Rect){
		$rect = [System.Drawing.Rectangle]::new(0,0,$Bitmap.Width, $Bitmap.Height)
	}

	$BytesPerPixel = [System.Drawing.Bitmap]::GetPixelFormatSize($Bitmap.PixelFormat) -shr 3

	$avg = [int[]]::new($BytesPerPixel)
	[array]::Fill($avg, 0)

	$data = $Bitmap.LockBits($Rect, "ReadOnly", $Bitmap.PixelFormat)
	$buf = [byte[]]::new($BytesPerPixel * $Rect.Width)

	$w = $Rect.Width
	$h = $Rect.Height

	# sum up the pixels
	$p = $data.Scan0
	for ($y = 0; $y -lt $h; ++$y){
		[System.Runtime.InteropServices.Marshal]::Copy($p, $buf, 0, $buf.Length)
		$p = [System.IntPtr]::Add($p, $data.Stride)
		for($x = 0; $x -lt $buf.Length; ++$x){
			$avg[$x % $avg.Length] += $buf[$x];
		}
	}
	$Bitmap.UnlockBits($data)

	# calc average
	for ($i = 0; $i -lt $avg.Count; $i++){
		$avg[$i] /= $w*$h
	}

	switch($BytesPerPixel)
	{
		3 { return BitInterleave $avg 8 }
		4 { return BitInterleave $avg[0..2] 8 }
	}
}

function BitInterleave([ulong[]]$Numbers, [int]$BitCount)
{
	for($i = 0; $i -lt $Numbers.Length; $i++)
	{
		$leadingZero = $Numbers[$i] -shr $BitCount
		if ($leadingZero -gt 0){
			Write-Error "$($Numbers[$i]) is too large ($leadingZero)"
			return
		}
	}
	$n = 0
	for($b = $BitCount-1; $b -ge 0; $b--)
	{
		for($i = 0; $i -lt $Numbers.Length; $i++)
		{
			# get bit from msb to lsb
			$bit = ($Numbers[$i] -shr $b) -band 1
			$n = $n -shl 1
			$n = $n -bor $bit
		}
	}
	return $n
}
filter BitExtraleave(
	[int]$Count,
	[Parameter(ValueFromPipeline=$true)][ulong]$Number
	)
{
	$numbers = [ulong[]]::new($Count)
	[array]::Fill($numbers, 0UL)
	$i = $Count-1
	$s = 0
	while($Number -gt 0){
		$bit = $Number -band 1
		$Number = $Number -shr 1
		$numbers[$i] = ($bit -shl $s) -bor ($numbers[$i])
		if ($i-- -eq 0)
		{
			$i = $Count-1
			$s++
		}
	}
	return $numbers
}

