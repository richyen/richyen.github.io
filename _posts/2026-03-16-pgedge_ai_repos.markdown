---
layout: post
title: "Learning AI Fast with pgEdge's RAG"
date: 2026-03-16
tags: postgres ai rag vector pgvector ollama docker mcp
categories: postgres
---

# Introduction

If you’ve been paying attention to the technology landscape recently, you’ve probably noticed that AI is **everywhere**. New frameworks, new terminology, and a dizzying array of acronyms and jargon: **LLM**, **RAG**, **embeddings**, **vector databases**, **MCP**, and more.

Honestly, it's been difficult to figure out where to start. Many tutorials either dive deep into machine learning theory (Bayesian transforms?) or hide everything behind a single API call to a hosted model.  Neither approach really explains how these systems actually work.

Recently I spent some time experimenting with the [pgEdge](https://www.pgedge.com) AI tooling after hearing Shaun Thomas' talk at a [PrairiePostgres](https://prairiepostgres.org/) meetup.  He talked about how to set up the various components of an AI chatbot system, starting from ingesting documents into a Postgres database, vectorizing the text, setting up a RAG and then an MCP server.

When I got home I wanted to try it out for myself -- props to the pgEdge team for making it all free an open-source!  What surprised me most was not just that everything worked, but how easy it was to get a complete AI retrieval pipeline running locally. More importantly, it turned out to be one of the clearest ways I’ve found to understand how modern AI systems are constructed behind the scenes.  Thanks so much, Shaun!

---

# The pgEdge AI Components

The pgEdge AI ecosystem provides several small tools that fit together naturally.  I'll go through them real quickly here

- [Doc Converter](https://github.com/pgEdge/doc-converter) -- The doc-converter normalizes documents into a format that is easy to process downstream. Whether the input is PDF, HTML, Markdown, or plain text, the converter produces clean text output suitable for ingestion.
- [Vectorizer](https://github.com/pgEdge/pgedge-vectorizer) -- The vectorizer handles the process of converting text chunks into embeddings.  These embeddings are numeric representations of text that capture semantic meaning. Once generated, they can be stored inside PostgreSQL using [pgvector](https://github.com/pgvector/pgvector) and queried with similarity search.
- [Retrieval-Augmented Generation (RAG) Server](https://github.com/pgEdge/pgedge-rag-server) -- The RAG framework ties everything together.  It orchestrates:
  1. embedding the user’s query
  2. retrieving similar document chunks
  3. assembling prompt context
  4. sending the prompt to an LLM
  5. returning the generated response

When the full system is running, you essentially have ChatGPT or Gemini running on your laptop

---

# Running Everything Locally with Ollama

With ChatGPT and Gemini, getting tokens or sharing my payment info was a blocker, especially if I just want to test stuff for educational purposes.  Through Shaun's presentation, I was introduced to [Ollama](https://ollama.com), which is a great alternative, if you're okay with slower performance (especially on a 8GB M1 Mac Mini).

I was pleasantly surprised at how easy it was to run the entire pipeline without relying on external AI APIs.  Specifically, I used the **embeddinggemma** model for generating embeddings.  This meant the entire stack could run locally, no API keys required!  Running everything locally removes those barriers and definitely makes experimentation much easier.

---

# Understanding RAG by Actually Running It

One of the most confusing concepts in learning AI prior to Shaun's talk was Retrieval-Augmented Generation (RAG).  I learned that what a RAG does is:

> Before asking the LLM to answer a question, retrieve relevant information and include it in the prompt.

With the pgEdge pipeline, the flow becomes very visible.

1. Documents are converted into clean text
2. Text is split into chunks
3. Chunks are embedded into vectors
4. Vectors are stored in PostgreSQL
5. A question is embedded into a vector
6. A similarity search finds relevant chunks
7. Those chunks are inserted into the prompt
8. The LLM generates the response

From this, I realized that the LLM is not storing my data.  Instead, the system retrieves relevant information *on demand* and feeds it into the prompt.  The RAG is a facilitator to the LLM's response.

---

# The Role of the Vectorizer

The vectorizer is a crucial step in the pipeline.  Its job is to convert human language into embeddings, which are high-dimensional numeric representations of meaning.  With vectors, searching with natural language becomes possible, instead of old-fashioned keyword matches.

Once the embeddings (vectorized documents) are stored in PostgreSQL using pgvector, everything starts to look familiar again for database engineers:

- indexing
- storage
- similarity search
- ranking results

Managing these things look pretty doable for a database guy like me 😂

---

# ~~Don't~~ Try This At Home!

After writing about the pgEdge stack I wanted to make it as easy as possible for others to reproduce the same experience, so I [packaged everything into a Docker Compose project](https://github.com/richyen/learn-ai-with-postgres).

Clone the repository and run:

```bash
git clone https://github.com/richyen/learn-ai-with-postgres.git
cd learn-ai-with-postgres
mkdir documents # put some txt files in there for vectorization
docker compose up --build
```

That single command:

1. Builds a custom PostgreSQL image with `pgvector` and `pgedge_vectorizer` compiled in
2. Starts an Ollama container and pulls the `embeddinggemma` and `glm-4.7-flash` models locally
3. Runs `pgedge-docloader` to ingest any documents you've put into the `documents/` folder
4. Calls `pgedge_vectorizer.enable_vectorization()`, which starts background workers inside Postgres that chunk and embed every page
5. Starts the RAG server on port 8080

No API keys, no cloud services. Everything runs on your own hardware.

Once the RAG server is up (watch for the setup container to exit cleanly), try asking it a question:

```bash
curl -s -X POST http://localhost:8080/v1/pipelines/pg-docs \
  -H "Content-Type: application/json" \
  -d '{"query": "How does autovacuum decide when to run?"}' \
  | jq .
```

The answer comes back a few seconds later, grounded in the actual PostgreSQL documentation:

```json
{
  "answer": "Autovacuum in PostgreSQL is triggered based on thresholds defined by two parameters: autovacuum_vacuum_threshold and autovacuum_vacuum_scale_factor. The daemon considers a table eligible for vacuuming when the number of dead tuples exceeds the threshold plus (scale_factor × total row count) ..."
}
```

You can also run raw similarity searches directly in SQL to see exactly what the retrieval step is doing before the LLM touches anything:

```sql
SELECT
    d.title,
    left(c.content, 200) AS snippet
FROM documents_content_chunks c
JOIN documents d ON c.source_id = d.id
WHERE c.embedding IS NOT NULL
ORDER BY c.embedding <=>
    pgedge_vectorizer.generate_embedding('autovacuum threshold configuration')
LIMIT 5;
```

This is the same pgvector `<=>` (cosine distance) operator the RAG server uses internally — you can inspect the retrieval step at any time without going through the HTTP API.

Embeddings are generated in the background by Postgres workers, so you can start querying as soon as a few hundred chunks are ready. Watch the progress with:

```bash
psql postgresql://postgres:password@localhost:5432/pgai -c "
SELECT
  (SELECT count(*) FROM documents)                                             AS total_docs,
  (SELECT count(*) FROM documents_content_chunks WHERE embedding IS NOT NULL)  AS vectorized;
"
```

The project also includes the pgedge-postgres-mcp server on port 8081, which exposes the knowledge base via the Model Context Protocol — so it can be wired directly into Claude Desktop, VS Code Copilot, or any other MCP-compatible client.

---
# Final Thoughts

There’s a lot of pressure right now to “learn AI,” but that phrase can mean many different things.  For people coming from infrastructure, databases, or backend engineering, one of the most approachable paths is simply:

> build a small RAG pipeline and observe how the pieces fit together.

The pgEdge tooling made this surprisingly straightforward.  Instead of assembling half a dozen unrelated frameworks, the components already fit together:

- doc ingestion
- vectorization
- PostgreSQL storage
- retrieval
- prompt generation
- LLM response

Once I saw the entire flow working end-to-end, the AI ecosystem makes a lot more sense.  Setting up the pgEdge RAG stack turned out to be a surprisingly effective way to see that architecture in action.

Enjoy!
