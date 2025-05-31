FROM node:18-alpine

# Set working directory
WORKDIR /app

# Copy package files and install dependencies
COPY package*.json ./
RUN npm install

# Copy rest of the app
COPY . .

# Expose Medusa's default port
ENV PORT=9000
EXPOSE 9000

# Start Medusa
CMD ["npm", "run", "start"]
