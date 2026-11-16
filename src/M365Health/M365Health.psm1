foreach ($folder in 'Private', 'Public') {
    $path = Join-Path -Path $PSScriptRoot -ChildPath $folder
    foreach ($file in Get-ChildItem -Path $path -Filter '*.ps1') {
        . $file.FullName
    }
}
