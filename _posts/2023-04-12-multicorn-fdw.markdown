---
layout: post
title:  "Making a Data Polyglot with PostgreSQL Foreign Data Wrappers"
date:   2023-04-12 13:00:00 -0800
tags: PostgreSQL postgres fdw foreign_data_wrappers multicorn
comments: true
categories: postgres
---

# With Foreign Data Wrappers, the possibilities are limitless

## Introduction
The old adage, "Don't put all your eggs in one basket" is certainly applicable to information management as well.  In this era, where information is distributed everywhere, from government archives to social media feeds, it is impractical to store and access data in one place.  Corollary to that, each method of storage has its strengths and weaknesses, so in some cases PostgreSQL may not be the best-suited database for caching, queueing, or distributing, when other database engines like Redis, Kafka, or Cassandra may do a better job.  While the aggregation visualization of this information can be challenging, PostgreSQL's Foreign Data Wrappers implementation empowers users to access many platforms seamlessly.

## What are Foreign Data Wrappers?
Foreign Data Wrappers (FDW) is PostgreSQL's implementation of [SQL/MED (SQL Management of External Data](https://wiki.postgresql.org/wiki/SQL/MED) that was added to the SQL standard in 2003.  It is a way to access external data that does not actually live within a specific PostgreSQL cluster.  There are many data sources, including flat files (.csv files), other RDBMSes (MySQL, Oracle, etc.), Google Spreadsheets, and even output from REST APIs, and FDWs allow Postgres users to access these data in tabular format, permitting `JOIN`s and filters, and thereby allowing deeper insights without having to migrate that information first.  FDW was first introduced in 2011 with read-only access to external data, and in 2013 write support was introduced in PostgreSQL 9.3.  Since then, [many FDWs have been written and published](https://wiki.postgresql.org/wiki/Foreign_data_wrappers), allowing Postgres users access to just about any information source imaginable.

## Multicorn Makes it Magical
The [PostgreSQL documentation](https://www.postgresql.org/docs/current/fdwhandler.html) specifies how to write a Foreign Data Wrapper, but not everyone is adept at coding in C.  Members of the community have created ways to make the creation of FDWs more accessible to people who are accustomed to coding in languages like Python and Ruby, and [Multicorn](https://multicorn.org/) is one of those interfaces.  In fact, over 50 of the FDWs listed on the [PostgreSQL Wiki page](https://wiki.postgresql.org/wiki/Foreign_data_wrappers) are written for access via Multicorn.  I'd heard of Multicorn before, and thought I would [give it a try](https://github.com/richyen/cloudsmith_fdw).  I had recently started working with [Cloudsmith](https://cloudsmith.com/), a package management platform with a [very nice API](https://help.cloudsmith.io/reference/introduction), and I figured maybe I could make an FDW to connect with our internal deployment portal.  To get started, I forked the [Mailchimp FDW](https://github.com/daamien/mailchimp_fdw) and started making a couple of classes for Cloudsmith:

```
class CloudsmithFDW(ForeignDataWrapper):
    def __init__(self,options,columns):
        super(CloudsmithFDW,self).__init__(options,columns)
        self.key=options.get('key',None)
        self.owner=options.get('owner','enterprisedb')
        self.repo=options.get('repo','dev')
        self.columns=columns

        self.page_size =  30

    def fetch(self):
        headers = {
          "accept": "application/json",
          "X-Api-Key": self.key
        }

        response = requests.get(self.url, headers=headers)

        return json.loads(response.text)

    def execute(self, quals, columns):
        for item in self.fetch():
            output = {}
            for column_name in self.columns:
                output[column_name] = item[column_name]
            yield output

class CloudsmithPackageFDW(CloudsmithFDW):
    def __init__(self,options,columns):
        super(CloudsmithPackageFDW,self).__init__(options,columns)
        self.url = f"https://api.cloudsmith.io/v1/packages/{self.owner}/{self.repo}/?sort=-date"
```

The Python code simply uses a `requests` call to send an HTTP `GET` to the Cloudsmith API, and stores the response as JSON.  From there, we load up the FDW and access the data:

```
CREATE EXTENSION multicorn;

CREATE SERVER cloudsmith_fdw 
FOREIGN DATA WRAPPER multicorn
options (
  wrapper 'cloudsmith_fdw.CloudsmithPackageFDW'
);

CREATE SCHEMA IF NOT EXISTS cloudsmith;

CREATE FOREIGN TABLE cloudsmith.packages (
        self_url TEXT,
        stage TEXT,
        status TEXT,
        sync_progress TEXT,
        downloads TEXT,
        extension TEXT,
        filename TEXT,
        "size" TEXT,
        repository TEXT,
        summary TEXT,
        version TEXT     -- See the Cloudsmith docs for other available columns
) server cloudsmith_fdw options (
   key 'your_secret_api_key'
);

SELECT * FROM cloudsmith.packages;
```

That's it!  With that, we're able to get information from Cloudsmith and work with it within PostgreSQL, just as if it were like any other table in the database.  Granted, the `cloudsmith_fdw` is not feature-complete, but the process is surprisingly simple, and there are additional features in Multicorn that can be leveraged to further refine the search.  With Multicorn, the possibilities are literally endless -- someone even ventured to [write a controller for their smart lightbulbs](https://github.com/rotten/hue-multicorn-postgresql-fdw).

## Conclusion
With FDWs, PostgreSQL continues to be "The World's Most Advanced Open Source Relational Database" by enabling users to work with many data sources without having to go through the tedious process of migration and validation.  I look forward to seeing the list of FDWs continue to expand on the PostgreSQL wiki page :raised_hands:
