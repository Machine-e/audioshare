using System.Collections.Concurrent;
using System.Text.Json;
using Windows.Devices.Bluetooth.Advertisement;

var scanSeconds = ParseIntArg(args, "--seconds", 12);
scanSeconds = Math.Clamp(scanSeconds, 3, 90);
var outputPath = ParseStringArg(args, "--output");

Console.OutputEncoding = System.Text.Encoding.UTF8;
var jsonOptions = new JsonSerializerOptions(JsonSerializerDefaults.Web)
{
    WriteIndented = false,
};

var records = new ConcurrentDictionary<ulong, BroadcastRecord>();
var totalEvents = 0;
var allowExtendedAdvertisements = false;
var watcher = new BluetoothLEAdvertisementWatcher
{
    ScanningMode = BluetoothLEScanningMode.Active,
};

try
{
    watcher.AllowExtendedAdvertisements = true;
    allowExtendedAdvertisements = true;
}
catch
{
    allowExtendedAdvertisements = false;
}

watcher.Received += (_, eventArgs) =>
{
    totalEvents++;
    var advertisement = eventArgs.Advertisement;
    var serviceUuids = advertisement.ServiceUuids
        .Select(uuid => uuid.ToString())
        .ToArray();
    var dataSections = advertisement.DataSections
        .Select(section => new DataSectionInfo(
            $"0x{section.DataType:X2}",
            (int)section.Data.Length))
        .ToArray();
    var manufacturerData = advertisement.ManufacturerData
        .Select(data => new ManufacturerInfo(
            $"0x{data.CompanyId:X4}",
            (int)data.Data.Length))
        .ToArray();

    var name = advertisement.LocalName ?? string.Empty;
    var address = eventArgs.BluetoothAddress;
    var advertisementType = eventArgs.AdvertisementType.ToString();
    var uuidText = string.Join(",", serviceUuids).ToLowerInvariant();
    var dataTypes = dataSections.Select(section => section.Type).ToHashSet();
    var isLikelyAuracast =
        advertisementType.Contains("Extended", StringComparison.OrdinalIgnoreCase) &&
        (dataTypes.Contains("0x30") ||
         dataTypes.Contains("0x16") ||
         uuidText.Contains("184f") ||
         uuidText.Contains("1850") ||
         uuidText.Contains("1851") ||
         uuidText.Contains("184e") ||
         name.Contains("Xiaomi", StringComparison.OrdinalIgnoreCase) ||
         name.Contains("Machine", StringComparison.OrdinalIgnoreCase));

    if (!isLikelyAuracast)
    {
        return;
    }

    records.AddOrUpdate(
        address,
        _ => new BroadcastRecord(
            Address: $"{address:X12}",
            Name: name,
            Rssi: eventArgs.RawSignalStrengthInDBm,
            AdvertisementType: advertisementType,
            Events: 1,
            ServiceUuids: serviceUuids,
            DataSections: dataSections,
            ManufacturerData: manufacturerData,
            LastSeenIso: DateTimeOffset.Now.ToString("O"),
            IsLikelyAuracast: isLikelyAuracast),
        (_, existing) => existing with
        {
            Name = string.IsNullOrWhiteSpace(name) ? existing.Name : name,
            Rssi = eventArgs.RawSignalStrengthInDBm,
            AdvertisementType = advertisementType,
            Events = existing.Events + 1,
            ServiceUuids = serviceUuids.Length == 0 ? existing.ServiceUuids : serviceUuids,
            DataSections = dataSections.Length == 0 ? existing.DataSections : dataSections,
            ManufacturerData = manufacturerData.Length == 0 ? existing.ManufacturerData : manufacturerData,
            LastSeenIso = DateTimeOffset.Now.ToString("O"),
            IsLikelyAuracast = existing.IsLikelyAuracast || isLikelyAuracast,
        });
};

string mode;
string? error = null;
try
{
    watcher.Start();
    await Task.Delay(TimeSpan.FromSeconds(scanSeconds));
    watcher.Stop();
    await Task.Delay(300);
    mode = records.IsEmpty ? "not_found" : "ready";
}
catch (Exception ex)
{
    mode = "error";
    error = $"{ex.GetType().Name}: {ex.Message}";
}

var broadcasts = records.Values
    .OrderByDescending(record => record.Events)
    .ThenByDescending(record => record.Rssi)
    .Take(20)
    .ToArray();

var result = new ScanResult(
    Mode: mode,
    Message: BuildMessage(mode, broadcasts.Length, scanSeconds, error),
    ScanSeconds: scanSeconds,
    TotalEvents: totalEvents,
    MatchedEvents: broadcasts.Sum(record => record.Events),
    AllowExtendedAdvertisements: allowExtendedAdvertisements,
    JoinApiAvailable: false,
    JoinApiNote: "Windows Runtime scanning can discover extended advertisements, but this helper does not expose an Auracast/BIS audio join path.",
    Broadcasts: broadcasts);

var json = JsonSerializer.Serialize(result, jsonOptions);
if (string.IsNullOrWhiteSpace(outputPath))
{
    Console.WriteLine(json);
}
else
{
    File.WriteAllText(outputPath, json, System.Text.Encoding.UTF8);
}

static int ParseIntArg(string[] args, string name, int fallback)
{
    for (var index = 0; index < args.Length - 1; index++)
    {
        if (string.Equals(args[index], name, StringComparison.OrdinalIgnoreCase) &&
            int.TryParse(args[index + 1], out var value))
        {
            return value;
        }
    }
    return fallback;
}

static string ParseStringArg(string[] args, string name)
{
    for (var index = 0; index < args.Length - 1; index++)
    {
        if (string.Equals(args[index], name, StringComparison.OrdinalIgnoreCase))
        {
            return args[index + 1];
        }
    }
    return string.Empty;
}

static string BuildMessage(string mode, int broadcastCount, int scanSeconds, string? error) =>
    mode switch
    {
        "ready" => $"Found {broadcastCount} likely Auracast/LE Audio broadcast(s) in {scanSeconds}s. Windows can discover the broadcast, but no public Auracast audio join API is available here.",
        "not_found" => $"No likely Auracast/LE Audio broadcast found in {scanSeconds}s. Keep HyperOS audio broadcast open and close enough to this PC.",
        "error" => $"Auracast scan failed: {error}",
        _ => "Auracast scan finished.",
    };

public sealed record ScanResult(
    string Mode,
    string Message,
    int ScanSeconds,
    int TotalEvents,
    int MatchedEvents,
    bool AllowExtendedAdvertisements,
    bool JoinApiAvailable,
    string JoinApiNote,
    BroadcastRecord[] Broadcasts);

public sealed record BroadcastRecord(
    string Address,
    string Name,
    int Rssi,
    string AdvertisementType,
    int Events,
    string[] ServiceUuids,
    DataSectionInfo[] DataSections,
    ManufacturerInfo[] ManufacturerData,
    string LastSeenIso,
    bool IsLikelyAuracast);

public sealed record DataSectionInfo(string Type, int Bytes);

public sealed record ManufacturerInfo(string CompanyId, int Bytes);
