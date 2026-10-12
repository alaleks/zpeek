DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS customers;

CREATE TABLE customers (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    city TEXT NOT NULL
);

CREATE TABLE orders (
    id INTEGER PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES customers(id),
    item TEXT NOT NULL,
    total_usd INTEGER NOT NULL
);

INSERT INTO customers VALUES
    (1, 'Ada', 'London'),
    (2, 'Grace', 'New York'),
    (3, 'Linus', 'Helsinki');

INSERT INTO orders VALUES
    (1, 1, 'Keyboard', 129),
    (2, 2, 'Monitor', 349),
    (3, 1, 'Mouse', 59),
    (4, 3, 'Laptop stand', 89),
    (5, 2, 'Dock', 199);
