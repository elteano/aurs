import std.algorithm;
import std.algorithm.searching;
import std.array;
import std.getopt;
import std.json;
import std.process;
import std.net.curl;
import std.typecons;
import std.stdio;

immutable aur_prefix = "https://aur.archlinux.org";
immutable search_prefix = aur_prefix ~ "/rpc/?v=5&type=search";
immutable info_prefix = aur_prefix ~ "/rpc/v5/info";

bool includeOutOfDate;
immutable print_format_string = "%-*.*s %-*.*s %s";

/*
 * General use flow:
 * search for package
 * - get package info to ensure it is the right one
 * - download package and dependencies
 * - build and install dependencies, build and install package
 *
 * ./aursv2 search pkgname
 * ./aursv2 info pkgname
 * ./aursv2 download --deps pkgname
 * ...?
 */

alias SubComDef = Tuple!(void function(string[]), "func", string, "description");

int main(string[] args)
{
    SubComDef[string] subs = [
        "search": SubComDef(&subSearch, "Search for a package by name."),
        "info": SubComDef(&subInfo, "Look up a specific package and get information."),
        "download": SubComDef(&subDownload, "Download a package tar file.")
    ];

    if (args.length < 2 || args[1] !in subs)
    {
        stderr.writefln("usage: %s [subcommand]", args[0]);
        foreach (key ; subs.keys)
        {
            stderr.writefln("   %10s  %s", key, subs[key].description);
        }
        return 1;
    }
    else
    {
        subs[args[1]].func(args[2..$]);
        return 0;
    }
}

void subSearch(string[] args)
{
  searchPackage(args[0]);
}

/**
 * Subcommand - get info on a package
 */
void subInfo(string[] args)
{
  auto pkgObj = getPackageInfo(args[0]);
  auto resultsObj = pkgObj["results"].array[0];
  foreach (item ; ["Name", "Version", "Description", "Maintainer", "URL", "URLPath", "Submitter"])
  {
    writefln("%-11s : %s", item, resultsObj[item].str);
  }
  if (resultsObj["Depends"].array.length > 0)
  {
    writefln("%-11s : %s", "Depends", resultsObj["Depends"].array[0].str);
    foreach (dep ; resultsObj["Depends"].array[1..$])
    {
      writefln("%-11s   %s", "", dep.str);
    }
  }
  else
  {
    writefln("%-11s :", "Depends");
  }
  if (resultsObj["License"].array.length > 0)
  {
    writefln("%-11s : %s", "License", resultsObj["License"].array[0].str);
    foreach (lic ; resultsObj["License"].array[1..$])
    {
      writefln("%-11s   %s", "", lic.str);
    }
  }
  else
  {
    writefln("%-11s :", "License");
  }
  foreach (item ; ["NumVotes", "Popularity"])
  {
    writefln("%-11s : %s", item, resultsObj[item].integer);
  }

  /*
  Repository      : extra
  Name            : zsh
  Version         : 5.9-4
  Description     : A very advanced and programmable command interpreter (shell) for UNIX
  Architecture    : x86_64
  URL             : https://www.zsh.org/
  Licenses        : custom
  Groups          : None
  Provides        : None
  Depends On      : pcre  libcap  gdbm
  Optional Deps   : None
  Conflicts With  : None
  Replaces        : None
  Download Size   : 2.23 MiB
  Installed Size  : 6.62 MiB
  Packager        : Frederik Schwan <freswa@archlinux.org>
  Build Date      : Tue 04 Jul 2023 02:09:21 AM PDT
  Validated By    : MD5 Sum  SHA-256 Sum  Signature
  */
}

void subDownload(string[] args)
{
  downloadPackage(args[0]);
}

auto lookupPackageName(string pkgname)
{
	string search_url = search_prefix ~ "&arg=" ~ pkgname;
	auto search_result = get(search_url);
	return parseJSON(search_result);
}

auto getPackageInfo(string pkgname)
{
    string info_url = info_prefix ~ "/" ~ pkgname;
    auto info_result = get(info_url);
    stdout.flush();
    return parseJSON(info_result);
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

auto getDependencies(string pkgname)
{
    auto infoObj = getPackageInfo(pkgname);
    foreach (dep ; infoObj["results"].array[0]["Depends"].array)
    {
        writeln(dep.str);
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
