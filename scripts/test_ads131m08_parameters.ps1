$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1')
$root = [string]$env:SIPEED_TANG20K_ROOT
$project = Join-Path $root 'cores\acquisition\ads131m08'
$rtl = Join-Path $project 'rtl'
$sim = Join-Path $project 'sim'
$sources = Get-ChildItem $rtl -Filter '*.v' | Sort-Object Name | ForEach-Object { $_.FullName.Replace('\', '/') }
$tb = (Join-Path $sim 'tb_ads131m08_param_guard.v').Replace('\', '/')

function Invoke-ParamCase([string]$Name, [string]$Override, [bool]$ShouldPass) {
    $vvp = (Join-Path $sim "param_$Name.vvp").Replace('\', '/')
    $extra = @()
    if ($Override) { $extra = @($Override) }
    $compileOutput = iverilog -g2012 @extra -o $vvp -s tb_ads131m08_param_guard $sources $tb 2>&1
    $compileExit = $LASTEXITCODE
    if ($ShouldPass) {
        if ($compileExit -ne 0) {
            $compileOutput | Out-Host
            throw "valid parameter case failed to compile: $Name"
        }
        vvp $vvp
        if ($LASTEXITCODE -ne 0) { throw "valid parameter case failed to run: $Name" }
    } elseif ($compileExit -eq 0) {
        $runOutput = & vvp $vvp 2>&1
        $runExit = $LASTEXITCODE
        if ($runExit -eq 0) {
            $runOutput | Out-Host
            throw "invalid parameter case unexpectedly passed: $Name"
        }
        Write-Host "PASS invalid parameter rejected at runtime: $Name"
    } else {
        Write-Host "PASS invalid parameter rejected during elaboration: $Name"
    }
}

Invoke-ParamCase 'valid' '' $true
foreach ($case in @(
    @('adc_count_max', '-Ptb_ads131m08_param_guard.ADC_COUNT=16'),
    @('fifo_depth_min', '-Ptb_ads131m08_param_guard.FIFO_DEPTH=2'),
    @('fifo_depth_large', '-Ptb_ads131m08_param_guard.FIFO_DEPTH=1024'),
    @('sck_div_zero', '-Ptb_ads131m08_param_guard.SCK_DIV=0'),
    @('clock_minimum', '-Ptb_ads131m08_param_guard.CLK_HZ=1'),
    @('osr_max', '-Ptb_ads131m08_param_guard.OSR_SEL=7'),
    @('pwr_max', '-Ptb_ads131m08_param_guard.PWR_SEL=3'),
    @('sched_priority', '-Ptb_ads131m08_param_guard.SCHED_DEFAULT=1'),
    @('addr_width_min', '-Ptb_ads131m08_param_guard.ADDR_W=12')
)) { Invoke-ParamCase $case[0] $case[1] $true }
foreach ($case in @(
    @('adc_count_zero', '-Ptb_ads131m08_param_guard.ADC_COUNT=0'),
    @('adc_count_large', '-Ptb_ads131m08_param_guard.ADC_COUNT=17'),
    @('fifo_not_power_two', '-Ptb_ads131m08_param_guard.FIFO_DEPTH=3'),
    @('sck_negative', '-Ptb_ads131m08_param_guard.SCK_DIV=-1'),
    @('clock_zero', '-Ptb_ads131m08_param_guard.CLK_HZ=0'),
    @('osr_large', '-Ptb_ads131m08_param_guard.OSR_SEL=8'),
    @('pwr_large', '-Ptb_ads131m08_param_guard.PWR_SEL=4'),
    @('sched_invalid', '-Ptb_ads131m08_param_guard.SCHED_DEFAULT=2'),
    @('addr_width_small', '-Ptb_ads131m08_param_guard.ADDR_W=11'),
    @('addr_width_too_small', '-Ptb_ads131m08_param_guard.ADDR_W=1')
)) { Invoke-ParamCase $case[0] $case[1] $false }
Write-Host 'ADS131M08 PARAMETER GUARD PASS: 10 valid boundary cases and 10 invalid cases rejected'
exit 0
