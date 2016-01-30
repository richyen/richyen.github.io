---
layout: post
title:  "Using Custom Types with Procedures in Postgres Plus Advanced Server"
date:   2016-01-29 17:03:09 -0800
tags: Java JDBC Types Procedures Oracle Postgresql
published: false
categories: postgres
---

# Introduction
Postgres Plus Advanced Server (known as EDB Postgres Advanced Server after the v. 9.5 release) provides Oracle compatibility and allows you to write packages and procedures, and lets you call them as all Oracle users are accustomed to.  However, there are a few minor pedantic changes you’ll need to get accustomed to in order to write packages and procedures correctly in Advanced Server.  When it comes to using Custom Types, you’ll need to be mindful of a few things.  We’ll go through a simple example so you can get on your way.

# An Example
Suppose you want to bulk-insert several thousand rows into a database, after combing it through with some business logic.  If you write a procedure that takes in as arguments all the data that fills in the columns of one row, it might look something like this:

{% highlight sql %}
CREATE PROCEDURE empInsert( e_name IN VARCHAR, e_sal IN VARCHAR) AS
$func$
  DECLARE
    CURSOR getMax is SELECT MAX(empno)+1 FROM emp;
    max_empno INT := 0;
  BEGIN
    OPEN getMax;
    FETCH getMax INTO max_empno;
    -- Do some logic here
    INSERT INTO emp(empno, ename, sal)
     VALUES(max_empno, e_name, e_Sal);
    CLOSE getMax;
  END;
$func$;
{% endhighlight %}

However, if you call this procedure thousands of times via your Java app, you might find that the roundtrip latency will slow you down.  Why not send *all* the data over to the database at once, and have a procedure iterate through the data set and insert it into the database?  In order to do this, you’ll need to use Custom Types, and the first two steps towards that are:

{% highlight sql %}
CREATE TYPE emp_sal_type AS OBJECT ( ename VARCHAR, sal VARCHAR );
CREATE TYPE emp_sal_tab AS TABLE OF emp_sal_type;
{% endhighlight %}

After that, you’re ready to create your procedure that will take in (as an array) all the data to be inserted, and use your original procedure (`empInsert`) to insert the data after applying the business logic:

{% highlight sql %}
CREATE PROCEDURE emptest_array(valuesArray IN emp_sal_tab) IS
$func$
  DECLARE
    i INT := 0;
  BEGIN
    FOR i IN valuesArray.FIRST..valuesArray.LAST LOOP
      empInsert(valuesArray(i).ename, valuesArray(i).sal);
    END LOOP;
  END;
$func$;
{% endhighlight %}

Once these components are in place, you can write up a simple Java app that looks something like this:

{% highlight java %}
import java.sql.CallableStatement;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Types;
import java.sql.SQLException;
import java.sql.Statement;
import java.sql.PreparedStatement;
import java.sql.CallableStatement;
import java.sql.Struct;
import java.sql.Array;

public class testJava {

  public static void main(String[] args) throws Exception {

    Connection con = null;
    Statement st = null;
    ResultSet rs = null;

    Integer val=5;
    String url = "jdbc:edb://localhost:5432/edb";
    String user = "enterprisedb";
    String password = "password";
    try {
      con = DriverManager.getConnection(url, user, password);
      String sql = "{call public.emptest_array(?)}";

      CallableStatement cs = con.prepareCall(sql);
      Struct emp1 = con.createStruct("emp_sal_type", new Object[]{"John Doe","543.21"});
      Struct emp2 = con.createStruct("emp_sal_type", new Object[]{"Jane Doe","987.65"});
      Array empArray = con.createArrayOf("emp_sal_type", new Object[]{emp1,emp2});
      cs.setObject(1, empArray, Types.OTHER);
      cs.execute();
    } catch (SQLException ex)
    {
      System.out.println(ex);
    }

    finally {
      try {
        if (con != null)
        {
          con.close();
        }
      } catch (SQLException ex)
      {
        System.out.println(ex);
      }
    }
  }
}
{% endhighlight %}

Compile it, run it, and you’re all set!

{% highlight text %}
[bash ~]$ psql -U enterprisedb -c “SELECT count(*) from emp” edb

 count 
-------
    29
(1 row)
edb=# 

[bash ~]$ javac -cp usr/ppas/connectors/jdbc/edb-jdbc17.jar testJava.java
[bash ~]$ java -cp usr/ppas/connectors/jdbc/edb-jdbc17.jar:. testJava

[bash ~]$ psql -U enterprisedb -c “SELECT count(*) from emp” edb

 count 
-------
    31
(1 row)
edb=# 
{% endhighlight %}
