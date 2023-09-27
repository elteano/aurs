import std.algorithm;
import std.array;
import std.getopt;
import std.json;
import std.process;
import std.net.curl;
import std.stdio;

immutable aur_prefix = "https://aur.archlinux.org";
immutable search_prefix = aur_prefix ~ "/rpc/?v=5&type=search";

bool includeOutOfDate;
immutable print_format_string = "%-*.*s %-*.*s %s";

void main(string[] args)
{
	string search = "";
	string download = "";
	auto helpInfo = getopt(
			args,
			"s|search", "Run a search query on the provided package name.", &search,
			"d|download", "Download the package information into a new folder.", &download,
			"ood", "Include out of date results.", &includeOutOfDate);
	if (search != "")
	{
		searchPackage(search);
	}
	else if (download != "")
	{
		downloadPackage(download);
	}
	else if (helpInfo.helpWanted)
	{
		defaultGetoptPrinter("Testing stuff", helpInfo.options);
	}
}

auto lookupPackageName(string pkgname)
{
	string search_url = search_prefix ~ "&arg=" ~ pkgname;
	auto search_result = get(search_url);
	return parseJSON(search_result);
}

void searchPackage(string pkgname)
{
	auto bundle = lookupPackageName(pkgname);
	auto goods = bundle["results"].array.filter!(r => (includeOutOfDate || r["OutOfDate"].isNull)).array;
	if (goods.length == 0)
	{
		writeln("No results found.");
	}
	else {
		ulong nameLen = getFieldMaxLen(goods, "Name");
		ulong maintLen = getFieldMaxLen(goods, "Maintainer");
		writefln(print_format_string, nameLen, nameLen, "Package", maintLen, maintLen, "Maintainer", "Description");
		foreach(r; goods)
		{
			string maint = r.tryGetField("Maintainer");
			string desc = r.tryGetField("Description");
			writefln(print_format_string, nameLen, nameLen, r["Name"].str, maintLen, maintLen, maint, desc);
		}
	}
}

ulong getFieldMaxLen(JSONValue[] searchable, string field)
{
	return max(5, searchable.filter!(s => !s[field].isNull).map!(s => s[field].str.length).maxElement);
}

string tryGetField(T)(T result, string fieldName)
{
	if (result[fieldName].isNull)
	{
		return "None";
	}
	else
	{
		return result[fieldName].str;
	}
}

void downloadPackage(string pkgname)
{
	auto bundle = lookupPackageName(pkgname);
	// Only get exact matches
	auto goods = bundle["results"].array.filter!(r => r["Name"].str == pkgname).array;
	if (goods.length == 0)
	{
		writeln("Package not found.");
	}
	else if (goods.length == 1)
	{
		writefln("Downloading package %s.", pkgname);
		auto result = executeShell("curl '" ~ aur_prefix ~ goods[0]["URLPath"].str ~ "' | tar -xz");
		if (result.status == 0)
		{
			writeln("Pakage downloaded.");
		}
		else
		{
			writeln("Error occurred with package download.");
		}
	}
	else
	{
		writeln("Multiple results found. Error.");
	}
}
