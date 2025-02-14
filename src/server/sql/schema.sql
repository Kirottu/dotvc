DROP TABLE IF EXISTS users;
CREATE TABLE users(
    username VARCHAR(20) NOT NULL,
    pass_hash TEXT NOT NULL,
    PRIMARY KEY(username)  
);

CREATE TABLE databases(
    username VARCHAR(20) NOT NULL,
    hostname VARCHAR(255) NOT NULL,
    PRIMARY KEY(username, hostname),
    FOREIGN KEY(username) REFERENCES users(username)
)
