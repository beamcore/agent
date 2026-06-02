function greet(name) {
  console.log('Hello, ' + name + '!');
}

const sum = (a, b) => {
  return a + b;
};

class User {
  constructor(name, role) {
    this.name = name;
    this.role = role;
  }

  isAdmin() {
    return this.role === 'admin';
  }
}
