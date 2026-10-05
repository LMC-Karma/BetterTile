// Same-origin browser export keeps vector sources editable without build dependencies.
export async function rasterizeAsset(file, width, height) {
  let svg=await fetch(`assets/identity/${file}.svg`).then(r=>{if(!r.ok)throw Error('SVG not found');return r.text();});
  if(svg.includes('<text')){
    const bytes=new Uint8Array(await fetch('assets/fonts/Inter-latin.woff2').then(r=>r.arrayBuffer()));
    let binary='';bytes.forEach(byte=>binary+=String.fromCharCode(byte));
    svg=svg.replace('</svg>',`<style>@font-face{font-family:Inter;src:url(data:font/woff2;base64,${btoa(binary)})}</style></svg>`);
  }
  const image=new Image(),url=URL.createObjectURL(new Blob([svg],{type:'image/svg+xml'}));
  try{image.src=url;await image.decode();const canvas=document.createElement('canvas');canvas.width=width;canvas.height=height;canvas.getContext('2d').drawImage(image,0,0,width,height);return canvas.toDataURL('image/png');}
  finally{URL.revokeObjectURL(url);}
}
for(const button of document.querySelectorAll('[data-export]'))button.addEventListener('click',async()=>{
  button.disabled=true;
  try{const [file,width,height]=button.dataset.export.split(',');const url=await rasterizeAsset(file,Number(width),Number(height));const a=document.createElement('a');a.href=url;a.download=`${file}-${width}.png`;a.click();document.querySelector('[role=status]').textContent='PNG exported. Place it in assets/identity, then rebuild.';}
  catch(error){document.querySelector('[role=status]').textContent=error.message;}
  finally{button.disabled=false;}
});
