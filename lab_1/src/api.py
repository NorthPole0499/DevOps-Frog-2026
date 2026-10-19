from flask import Flask, request

app = Flask(__name__)

allocated_memory = []

@app.get("/health")
def health():
	return "ok\n"

@app.get("/eat")
def eat():
	mb = int(request.args.get("mb", 1))

	block = bytearray(mb * 1024 * 1024)
	allocated_memory.append(block)

	return f"Allocated and holding {mb} MB\n"

@app.get("/burn")
def burn():
	while True:
		pass

if __name__ == "__main__":
	app.run(host="0.0.0.0", port=8080)
