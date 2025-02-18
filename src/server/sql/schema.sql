CREATE TABLE users(
    username VARCHAR(20) NOT NULL,
    pass_hash TEXT NOT NULL,
    PRIMARY KEY(username)  
);

CREATE TABLE auth_tokens(
    token VARCHAR(32) NOT NULL,
    username VARCHAR(20) NOT NULL,
    last_used TIMESTAMP NOT NULL,
    PRIMARY KEY(token),
    FOREIGN KEY(username) REFERENCES users(username)
);

CREATE TABLE db_manifests(
    username VARCHAR(20) NOT NULL,
    hostname VARCHAR(255) NOT NULL,
    modified TIMESTAMP NOT NULL,
    PRIMARY KEY(username, hostname),
    FOREIGN KEY(username) REFERENCES users(username)
);
