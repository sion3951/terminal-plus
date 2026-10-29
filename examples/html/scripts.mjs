import { Counter, formatCount } from './support.mjs';
const counter=new Counter();
document.getElementById('module-result').textContent='Module import and class construction: working';
document.getElementById('increment').addEventListener('click',()=>{counter.increment();document.getElementById('count').textContent=formatCount(counter.value);});
document.getElementById('regex-result').textContent='Native regular expression: '+'one  two   three'.replace(/\s+/g,' · ');
async function loadData(){try{const response=await fetch('./data.json');const data=await response.json();document.getElementById('fetch-result').textContent=data.message;}catch(error){document.getElementById('fetch-result').textContent='Fetch error: '+error;}}
loadData();
